import SwiftUI

// MARK: - ScreenHeader
// A custom tight header for tab-root screens, replacing the system large-title navigation bar.
// Sits as the first element inside each tab's ScrollView so it scrolls naturally with content
// and clears the status bar / Dynamic Island by respecting the top safe-area inset.
//
// Usage:
//   ScreenHeader("Today")               // title only
//   ScreenHeader("Today") { MyButton() } // title + trailing accessory

struct ScreenHeader<Trailing: View>: View {
    let title: String
    let trailing: Trailing

    init(_ title: String, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(WH.Color.textPrimary)
                .lineLimit(1)

            Spacer(minLength: WH.Spacing.sm)

            trailing
        }
        // Tight top: just enough space below the status bar/Dynamic Island (~8 pt) —
        // the safe-area inset itself is already respected by the enclosing ScrollView.
        .padding(.top, WH.Spacing.sm)
        .padding(.bottom, WH.Spacing.xs)
        .padding(.horizontal, WH.Spacing.md)
        .background(WH.Color.background)
    }
}

// MARK: - Convenience init (title-only, no trailing accessory)

extension ScreenHeader where Trailing == EmptyView {
    init(_ title: String) {
        self.init(title) { EmptyView() }
    }
}
