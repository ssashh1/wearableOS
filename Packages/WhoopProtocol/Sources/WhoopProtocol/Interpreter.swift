import Foundation

public struct DecodedField: Codable, Equatable {
    public let off: Int
    public let len: Int
    public let name: String
    public let cat: String
    public let value: ParsedValue?
    public let raw: String
    public let note: String?
}

public struct ParsedFrame: Codable, Equatable {
    public let ok: Bool
    public let typeName: String
    public let seq: Int?
    public let cmdName: String?
    public let crcOK: Bool?
    public let lenBytes: Int
    public let rawHex: String
    public let fields: [DecodedField]
    public let parsed: [String: ParsedValue]
}

// MARK: - low-level readers (LE), nil when out of range (mirrors interpreter._read)

@inline(__always) private func readU8(_ f: [UInt8], _ off: Int) -> Int? {
    off + 1 <= f.count ? Int(f[off]) : nil
}
@inline(__always) private func readU16(_ f: [UInt8], _ off: Int) -> Int? {
    off + 2 <= f.count ? Int(f[off]) | (Int(f[off + 1]) << 8) : nil
}
@inline(__always) private func readU32(_ f: [UInt8], _ off: Int) -> Int? {
    guard off + 4 <= f.count else { return nil }
    return Int(f[off]) | (Int(f[off + 1]) << 8) | (Int(f[off + 2]) << 16) | (Int(f[off + 3]) << 24)
}
@inline(__always) private func readI16(_ f: [UInt8], _ off: Int) -> Int? {
    guard off + 2 <= f.count else { return nil }
    let raw = UInt16(f[off]) | (UInt16(f[off + 1]) << 8)
    return Int(Int16(bitPattern: raw))
}

/// Read a schema dtype at off; returns the integer value or nil if out of range.
private func readDType(_ f: [UInt8], _ off: Int, _ dtype: String) -> Int? {
    switch dtype {
    case "u8": return readU8(f, off)
    case "u16": return readU16(f, off)
    case "u32": return readU32(f, off)
    case "i16": return readI16(f, off)
    default: return nil
    }
}

private func hexString(_ bytes: ArraySlice<UInt8>) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

/// Field builder: accumulates annotated fields and a flat parsed dict. Port of Python FB.
final class FieldBuilder {
    let frame: [UInt8]
    var fields: [DecodedField] = []
    var parsed: [String: ParsedValue] = [:]

    init(_ frame: [UInt8]) {
        self.frame = frame
    }

    @discardableResult
    func add(_ off: Int, _ length: Int, _ name: String, _ cat: String,
             value: ParsedValue? = nil, note: String? = nil) -> FieldBuilder {
        let end = min(off + length, frame.count)
        let raw = off <= frame.count ? hexString(frame[max(0, off)..<max(off, end)]) : ""
        fields.append(DecodedField(off: off, len: length, name: name, cat: cat,
                                   value: value, raw: raw, note: note))
        if value != nil && cat != "frame" && cat != "unknown" {
            parsed[name] = value
        }
        return self
    }

    func region(_ start: Int, _ end: Int, _ name: String, _ cat: String, note: String? = nil) {
        if start < end && end <= frame.count {
            add(start, end - start, name, cat, value: .string("[\(end - start) bytes]"), note: note)
        }
    }
}

public func parseFrame(_ frame: [UInt8]) -> ParsedFrame {
    let rawHex = frame.map { String(format: "%02x", $0) }.joined()
    if frame.count < 8 || frame[0] != 0xAA {
        return ParsedFrame(ok: false, typeName: "INVALID/FRAGMENT", seq: nil, cmdName: nil,
                           crcOK: nil, lenBytes: frame.count, rawHex: rawHex,
                           fields: [], parsed: [:])
    }

    let schema = loadSchema()
    let check = verifyFrame(frame)
    let length = check.length
    let crcOK = check.crc32OK

    let t = Int(frame[4])
    let typeName = schema.typeName(t)
    let seq = Int(frame[5])

    let fb = FieldBuilder(frame)
    // envelope
    fb.add(0, 1, "SOF", "frame", value: .string("0xAA"))
    fb.add(1, 2, "length", "frame", value: length.map { .int($0) })
    fb.add(3, 1, "crc8", "frame", value: .string(String(format: "0x%02X", frame[3])))
    fb.add(4, 1, "packet_type", "frame", value: .string(typeName))
    fb.add(5, 1, "seq", "frame", value: .int(Int(frame[5])))

    let spec = schema.packet(forType: t)
    if spec == nil {
        fb.add(6, 1, "cmd", "cmd", value: frame.count > 6 ? .int(Int(frame[6])) : nil)
        if let length = length { fb.region(7, length, "payload", "unknown") }
    } else {
        // static fields from schema
        for fld in spec!.fields {
            guard let dtype = fld.dtype else { continue }
            guard let val = readDType(frame, fld.off, dtype) else { continue }
            let value: ParsedValue
            if let enumKey = fld.`enum` {
                value = .string(schema.enumName(enumKey, val))
            } else {
                value = .int(val)
            }
            fb.add(fld.off, fld.len, fld.name, fld.cat, value: value, note: fld.note)
        }
        // per-type post-hook for irregular fields (populated in PostHooks.swift by B7)
        if let postName = spec!.post, let hook = postHooks[postName] {
            hook(fb, frame, length, schema)
        }
    }

    // crc32 trailer field
    if let length = length, length + 4 <= frame.count {
        let crcVal = UInt32(frame[length]) | (UInt32(frame[length + 1]) << 8)
            | (UInt32(frame[length + 2]) << 16) | (UInt32(frame[length + 3]) << 24)
        fb.add(length, 4, "crc32", "frame", value: .string(String(format: "0x%08X", crcVal)),
               note: check.crc32OK == true ? "OK" : "MISMATCH")
    }

    let cmdByte = frame.count > 6 ? Int(frame[6]) : 0
    let cmdName = (t == 35 || t == 36) ? schema.enumName("CommandNumber", cmdByte) : nil

    return ParsedFrame(ok: true, typeName: typeName, seq: seq, cmdName: cmdName,
                       crcOK: crcOK, lenBytes: frame.count, rawHex: rawHex,
                       fields: fb.fields, parsed: fb.parsed)
}

// Post-hook registry (populated in PostHooks.swift by Task B7).
// name -> (FieldBuilder, frame, length, schema) -> Void
typealias PostHook = (FieldBuilder, [UInt8], Int?, Schema) -> Void
var postHooks: [String: PostHook] = [:]
