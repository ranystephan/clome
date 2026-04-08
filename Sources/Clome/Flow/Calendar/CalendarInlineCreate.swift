import SwiftUI

/// Ghost card rendered while the user is creating an event inline.
/// Auto-focuses the title field; Enter commits, Esc cancels.
struct CalendarInlineCreate: View {
    let start: Date
    let end: Date
    @Binding var title: String
    var onCommit: () -> Void
    var onCancel: () -> Void

    @FocusState private var focused: Bool

    private let tint = FlowTokens.accent

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tint.opacity(0.95))
                .frame(width: 2)

            VStack(alignment: .leading, spacing: 1) {
                TextField("New event", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(tint.opacity(0.95))
                    .focused($focused)
                    .onAppear { focused = true }
                    .onSubmit { onCommit() }
                    .onExitCommand { onCancel() }

                if end.timeIntervalSince(start) >= 25 * 60 {
                    Text(timeLabel)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(tint.opacity(0.55))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.opacity(0.22))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(tint.opacity(0.7), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private var timeLabel: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return "\(f.string(from: start))–\(f.string(from: end))"
    }
}
