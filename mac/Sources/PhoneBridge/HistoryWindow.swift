import AppKit
import SwiftUI
import PhoneBridgeCore

final class HistoryModel: ObservableObject {
    @Published var entries: [HistoryEntry] = []
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    let iconFor: (String) -> NSImage?
    let onClear: () -> Void

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Recent notifications")
                    .font(.headline)
                Spacer()
                Button("Clear") { onClear() }
                    .disabled(model.entries.isEmpty)
            }
            .padding(12)
            Divider()

            if model.entries.isEmpty {
                Spacer()
                Text("Nothing yet")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.entries) { entry in
                            row(entry)
                            Divider().padding(.leading, 60)
                        }
                    }
                }
            }
        }
        .frame(width: 420, height: 480)
    }

    private func row(_ entry: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if let icon = iconFor(entry.iconHash) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.indigo.opacity(0.85))
                        Image(systemName: "bell.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                    }
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title.isEmpty ? entry.appName : entry.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Self.timeFormat.string(
                        from: Date(timeIntervalSince1970: entry.receivedAt)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(entry.appName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
