import SwiftUI

struct StatusRow: View {
    let label: String
    let ok: Bool
    let okText: String
    let notOkText: String

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(label)
            Spacer()
            Text(ok ? okText : notOkText)
                .foregroundStyle(.secondary)
        }
    }
}
