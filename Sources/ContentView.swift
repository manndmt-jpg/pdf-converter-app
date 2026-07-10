import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var queue: ConversionQueue
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            dropZone
            if !queue.items.isEmpty {
                queueList
            }
            if queue.items.isEmpty && !queue.history.isEmpty {
                recentList
            }
            Spacer(minLength: 0)
            footer
        }
        .padding(14)
        .frame(width: 440, height: 560)
    }

    // MARK: - Drop zone

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.doc")
                .font(.system(size: queue.items.isEmpty ? 40 : 24, weight: .light))
                .foregroundStyle(isDropTargeted ? Color.accentColor : .secondary)
            Text("Drop PDFs here")
                .font(queue.items.isEmpty ? .title3 : .callout)
                .foregroundStyle(.secondary)
            Button("Browse…") { browse() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .frame(height: queue.items.isEmpty ? 200 : 110)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                    style: StrokeStyle(lineWidth: 2, dash: [6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
                )
        )
        .animation(.easeInOut(duration: 0.15), value: queue.items.isEmpty)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            queue.add(urls: panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    ConversionQueue.shared.add(urls: [url])
                }
            }
        }
        return handled
    }

    // MARK: - Queue

    private var queueList: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(queue.items) { item in
                    QueueRow(item: item)
                }
            }
        }
    }

    // MARK: - Recents

    private var recentList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(queue.history) { entry in
                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: entry.outputPath))
                } label: {
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.secondary)
                        Text(entry.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(entry.date, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Output Folder") {
                NSWorkspace.shared.open(AppSettings.current().outputFolder)
            }
            .controlSize(.small)
            if queue.items.contains(where: { ConversionQueue.isFinished($0.status) }) {
                Button("Clear Finished") { queue.clearFinished() }
                    .controlSize(.small)
            }
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Queue row

struct QueueRow: View {
    let item: QueueItem
    @EnvironmentObject var queue: ConversionQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                statusIcon
                Text(item.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                trailingControls
            }
            detailLine
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.07)))
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .waiting:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .awaitingConfirmation:
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
        case .converting:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled:
            Image(systemName: "slash.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var trailingControls: some View {
        switch item.status {
        case .waiting, .converting:
            Button {
                queue.cancel(item.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        case .done(let url):
            Button("Open") { NSWorkspace.shared.open(url) }
                .controlSize(.small)
            removeButton
        case .failed:
            Button("Retry") { queue.retry(item.id) }
                .controlSize(.small)
            removeButton
        case .cancelled:
            removeButton
        case .awaitingConfirmation:
            EmptyView()
        }
    }

    private var removeButton: some View {
        Button {
            queue.remove(item.id)
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Remove from list")
    }

    @ViewBuilder private var detailLine: some View {
        switch item.status {
        case .converting(let detail, let fraction):
            VStack(alignment: .leading, spacing: 2) {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let fraction {
                    ProgressView(value: fraction)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .awaitingConfirmation(let pageCount):
            HStack {
                Text("\(pageCount) scanned pages — this costs one AI call per page.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Skip") { queue.confirmLargeFile(item.id, proceed: false) }
                    .controlSize(.mini)
                Button("Convert") { queue.confirmLargeFile(item.id, proceed: true) }
                    .controlSize(.mini)
                    .buttonStyle(.borderedProminent)
            }
        case .waiting:
            Text("Waiting…")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .cancelled:
            Text("Cancelled")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case .done:
            EmptyView()
        }
    }
}
