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

    @State private var expanded: Set<UUID> = []

    private static let timeFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color(red: 0.95, green: 0.94, blue: 0.98))
                        .frame(width: 30, height: 30)
                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.49, green: 0.44, blue: 0.87))
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Recent notifications")
                        .font(.headline)
                    Text("\(model.entries.count) mirrored from your phone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear") { onClear() }
                    .disabled(model.entries.isEmpty)
            }
            .padding(14)
            .background(Color(nsColor: .windowBackgroundColor))
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
        let isExpanded = expanded.contains(entry.id)
        return HStack(alignment: .top, spacing: 12) {
            Group {
                if entry.isCall {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.20, green: 0.65, blue: 0.44).opacity(0.15))
                        Image(systemName: "phone.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(red: 0.20, green: 0.65, blue: 0.44))
                    }
                } else if let icon = iconFor(entry.iconHash) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(red: 0.95, green: 0.94, blue: 0.98))
                        Image(systemName: "bell.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color(red: 0.49, green: 0.44, blue: 0.87))
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
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(entry.appName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if entry.text.count > 90 {
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isExpanded {
                    expanded.remove(entry.id)
                } else {
                    expanded.insert(entry.id)
                }
            }
        }
    }
}
