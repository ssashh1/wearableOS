"""Crack the WHOOP 4.0 type-43 REALTIME_RAW_DATA 1921-byte OPTICAL/PPG array.

================================  VERDICT  ====================================
The 1921-byte type-43 OPTICAL packet carries a SINGLE AC-coupled PPG waveform
(high-pass filtered, DC-removed by the strap DSP), NOT a multi-channel raw AFE
dump. Structure (verified against phase ground-truth):

  bytes [0:8]    shared header w/ the 1917 IMU packet:
                   [0:4] u32 LE frame counter A (.. a5 31 02)
                   [4:8] u32 LE frame counter B (.. 4e e1 01)  (A,B step +1/packet)
  bytes [8:35]   optical sub-header / config TLV (16 0d xx triples, 20 03 ..,
                 plausibly LED-current / channel-config metadata - NOT decoded)
  bytes [35:1713] sample array:
                   stride = 4 bytes/sample        (VERIFIED: byte-autocorr lag-4 = .92)
                   sample value = bytes[0:3] as 24-bit SIGNED little-endian
                                  (VERIFIED: byte[2] is correct sign-extension 98% at off 35)
                   byte[3]      = aux/status byte: sign-ext copy ~73%, else small
                                  markers (2,3,4,16,20..) clustered in bursts - NOT a
                                  clean 2nd channel (UNKNOWN exact meaning)
                   ~419 samples/packet, packets ~1/s -> ~0.4-0.5 kHz sample rate (PROBABLE)
  bytes [1713:1921] zero padding (fixed-size packet)

PHASE EVIDENCE (the labeling ground truth):
  finger : large pulsatile AC (IQR ~71000), FFT peak 1.0-1.1 Hz + 2.1 Hz harmonic
           = ~60-65 bpm heart rate.  <- unambiguous PPG.
  wrist  : small AC (IQR ~270), weak/variable pulse  <- weaker wrist perfusion.
  air    : AC -> 0 (flatlines)  <- no tissue, no pulse.
  (no `light`/ambient phase present in this capture)

CHANNEL LABEL: the one decoded channel = pulsatile PPG, almost certainly GREEN
LED (HR channel). Red/IR/ambient channels are NOT separately present in this
packet stream (they live in the DSP'd historical V24 fields ppg_green/ppg_red_ir,
or in a different sub-stream we don't see here). LED-wavelength mapping & absolute
ADC scaling/gain remain UNKNOWN.

DECODABILITY: the PPG waveform is decodable losslessly (4-byte stride, s24 LE,
offset 35) into one labeled AC PPG channel. But because byte[3] semantics and the
[8:35] config block are not fully resolved, and only one channel is recoverable,
this does NOT fully retire raw upload for type-43 -- keep raw for the unknown
bytes; the PPG channel itself can be extracted/downsampled locally.
===============================================================================

Run:  whoop-reader/.venv/bin/python re/analyze_optical.py
"""
import json
import numpy as np

CAP = "fixtures/optical_capture.jsonl"
HDR_LEN = 8          # shared header w/ IMU packet
ARRAY_OFF = 35       # first byte of the optical sample array (VERIFIED via sign-byte)
ARRAY_END = 1713     # one past last non-zero payload byte (constant across packets)
STRIDE = 4           # bytes per sample (VERIFIED: byte-autocorr lag-4)
PKT_INTERVAL = 0.959 # median seconds between optical packets (from wall clock)


def load():
    rows = []
    for line in open(CAP):
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return rows


def optical_packets(rows, phase=None):
    return [bytes.fromhex(r["data_hex"]) for r in rows
            if r["datalen"] == 1921 and (phase is None or r["phase"] == phase)]


def decode_ppg(d):
    """Return (ppg_s24, aux_byte3) arrays for one optical packet."""
    a = np.frombuffer(d, dtype=np.uint8).astype(np.int64)
    body = a[ARRAY_OFF:ARRAY_END]
    n = len(body) // STRIDE
    m = body[:n * STRIDE].reshape(n, STRIDE)
    v = m[:, 0] | (m[:, 1] << 8) | (m[:, 2] << 16)
    v = np.where(v >= 2 ** 23, v - 2 ** 24, v)        # 24-bit signed
    return v, m[:, 3]


def hr_peak(sig, fs):
    """Return (HR-band power ratio, peak Hz) after robust de-spike + DC removal."""
    sig = np.asarray(sig, float)
    if len(sig) < 16:
        return 0.0, 0.0
    med = np.median(sig)
    mad = np.median(np.abs(sig - med)) + 1
    sig = np.clip(sig, med - 8 * mad, med + 8 * mad)
    sig = sig - sig.mean()
    if sig.std() == 0:
        return 0.0, 0.0
    f = np.fft.rfftfreq(len(sig), 1.0 / fs)
    p = np.abs(np.fft.rfft(sig)) ** 2
    band = (f >= 0.7) & (f <= 2.5)
    if p[1:].sum() == 0:
        return 0.0, 0.0
    ratio = p[band].sum() / p[1:].sum()
    return ratio, f[1:][np.argmax(p[1:])]


def main():
    rows = load()
    o = optical_packets(rows)
    imu = [bytes.fromhex(r["data_hex"]) for r in rows if r["datalen"] == 1917]
    n_samp = (ARRAY_END - ARRAY_OFF) // STRIDE
    fs = n_samp / PKT_INTERVAL

    print("=== packets ===")
    print(f"optical(1921)={len(o)}  imu(1917)={len(imu)}")
    print(f"samples/packet={n_samp}  packet interval={PKT_INTERVAL}s  => ~{fs:.0f} Hz (probable)")

    print("\n=== shared header ===")
    print(f"OPT [0:8]={o[0][:8].hex()}   IMU [0:8]={imu[0][:8].hex()}")
    print(f"OPT sub-header [8:35]={o[0][8:ARRAY_OFF].hex()}")

    print("\n=== structural verification (finger packet 0) ===")
    a = np.frombuffer(o[0], np.uint8)
    body = a[ARRAY_OFF:ARRAY_END]
    bb = body.astype(float) - body.mean()
    ac = np.correlate(bb, bb, "full")[len(bb) - 1:]; ac /= ac[0]
    print(f"byte-autocorr lag4={ac[4]:.2f} lag8={ac[8]:.2f} (stride=4 confirmed)")
    m = body[:(len(body)//4)*4].reshape(-1, 4).astype(np.int64)
    v = m[:, 0] | (m[:, 1] << 8) | (m[:, 2] << 16)
    vs = np.where(v >= 2**23, v - 2**24, v)
    sign_ok = np.mean((m[:, 2] == 0) | (m[:, 2] == 255))
    print(f"byte[2]-is-sign-extension frac={sign_ok:.3f} (s24 LE confirmed)")
    print(f"first 12 PPG samples: {vs[:12].tolist()}")

    print("\n=== phase-based channel labeling (the ground truth) ===")
    print(f"{'phase':7} {'pkts':>4} {'AC IQR':>9} {'HRpulse':>8} {'peakHz':>7} {'bpm':>5}")
    for ph in ("finger", "wrist", "air"):
        pk = optical_packets(rows, ph)
        iqrs, ratios, peaks = [], [], []
        for d in pk:
            v, _ = decode_ppg(d)
            iqrs.append(np.percentile(v, 75) - np.percentile(v, 25))
            r, hz = hr_peak(v, fs)
            ratios.append(r); peaks.append(hz)
        med_iqr = np.median(iqrs)
        # only trust the HR peak where there is real AC (finger/wrist)
        good = [(r, hz) for r, hz, q in zip(ratios, peaks, iqrs) if q > 100]
        if good:
            r = np.mean([g[0] for g in good]); hz = np.median([g[1] for g in good])
            bpm = hz * 60
        else:
            r = hz = bpm = 0.0
        print(f"{ph:7} {len(pk):>4} {med_iqr:>9.0f} {r:>8.2f} {hz:>7.2f} {bpm:>5.0f}")

    print("\nLabel: the single decoded channel is PULSATILE PPG (green/HR LED).")
    print("Red/IR/ambient not separately present here. Scaling/wavelength UNKNOWN.")


if __name__ == "__main__":
    main()
