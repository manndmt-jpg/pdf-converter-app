import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Two-pane redesign ("1c") from the claude.ai/design handoff:
// sidebar = queue + recent, main pane = selected document's live state.
struct ContentView: View {
    @EnvironmentObject var queue: ConversionQueue
    @State private var selection: SidebarSelection?
    @State private var isDropTargeted = false
    @State private var dragCount = 0

    enum SidebarSelection: Hashable {
        case item(UUID)
        case history(String)   // output path
    }

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selection: $selection)
                .frame(width: 264)
            Rectangle().fill(DS.hairline).frame(width: 1)
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.windowBg.ignoresSafeArea())
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 700, minHeight: 460)
        .overlay { if isDropTargeted { DragOverlay(count: dragCount) } }
        .onDrop(of: [.fileURL], delegate: WindowDropDelegate(
            isTargeted: $isDropTargeted, count: $dragCount))
        .onChange(of: queue.activeItemID) { _, active in
            // Auto-follow the conversion that just started
            if let active { selection = .item(active) }
        }
        .onChange(of: queue.items) { _, items in
            // Clear selection when the selected row disappears (removed/cleared)
            if case .item(let id) = selection, !items.contains(where: { $0.id == id }) {
                selection = nil
            }
        }
    }

    @ViewBuilder private var detailPane: some View {
        switch selection {
        case .item(let id):
            if let item = queue.items.first(where: { $0.id == id }) {
                ItemDetailView(item: item)
            } else {
                EmptyStateView()
            }
        case .history(let path):
            HistoryDetailView(outputURL: URL(fileURLWithPath: path))
        case nil:
            EmptyStateView()
        }
    }
}

// MARK: - Whole-window drop

struct WindowDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var count: Int

    func dropEntered(info: DropInfo) {
        count = info.itemProviders(for: [.fileURL]).count
        isTargeted = true
    }

    func dropExited(info: DropInfo) { isTargeted = false }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in ConversionQueue.shared.add(urls: [url]) }
            }
        }
        return !providers.isEmpty
    }
}

struct DragOverlay: View {
    let count: Int

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: NSColor(name: nil) { $0.isDark
                ? NSColor(red: 0.078, green: 0.055, blue: 0.051, alpha: 0.72)
                : NSColor(red: 0.980, green: 0.973, blue: 0.965, alpha: 0.78) }))
            RoundedRectangle(cornerRadius: 9)
                .strokeBorder(DS.accent.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [8]))
                .padding(10)
            VStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(DS.accent)
                        .frame(width: 64, height: 64)
                        .shadow(color: DS.accent.opacity(0.5), radius: 18, y: 4)
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                }
                Text(count == 1 ? "Release to add 1 PDF" : "Release to add \(count) PDFs")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                Text("They join the queue and convert one after another")
                    .font(.system(size: 12))
                    .foregroundStyle(DS.accentMutedText)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var queue: ConversionQueue
    @Binding var selection: ContentView.SidebarSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 52) // traffic-light spacer
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sectionHeader("Queue")
                    if activeItems.isEmpty {
                        Text("Empty — drop PDFs to start")
                            .font(.system(size: 12))
                            .foregroundStyle(DS.textQuaternary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(activeItems) { item in
                            QueueRowView(item: item, isSelected: selection == .item(item.id))
                                .onTapGesture { toggle(.item(item.id)) }
                        }
                    }
                    if !finishedItems.isEmpty || !todayHistory.isEmpty {
                        sectionHeader("Done today").padding(.top, 14)
                        ForEach(finishedItems) { item in
                            QueueRowView(item: item, isSelected: selection == .item(item.id))
                                .onTapGesture { toggle(.item(item.id)) }
                        }
                        ForEach(todayHistory) { entry in
                            HistoryRowView(entry: entry, isSelected: selection == .history(entry.outputPath),
                                           onRemove: { removeHistory(entry) })
                                .onTapGesture { toggle(.history(entry.outputPath)) }
                        }
                    }
                    if !olderHistory.isEmpty {
                        sectionHeader("Recent").padding(.top, 14)
                        ForEach(olderHistory) { entry in
                            HistoryRowView(entry: entry, isSelected: selection == .history(entry.outputPath),
                                           onRemove: { removeHistory(entry) })
                                .onTapGesture { toggle(.history(entry.outputPath)) }
                        }
                    }
                }
                .padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
            footer
        }
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                // Warm tint per spec: light rgba(233,229,226,0.75), dark rgba(50,48,47,0.6)
                Rectangle().fill(Color(nsColor: NSColor(name: nil) { $0.isDark
                    ? NSColor(red: 0.196, green: 0.188, blue: 0.184, alpha: 0.6)
                    : NSColor(red: 0.914, green: 0.898, blue: 0.886, alpha: 0.75) }))
            }
            .ignoresSafeArea()
        }
    }

    private func toggle(_ target: ContentView.SidebarSelection) {
        selection = (selection == target) ? nil : target
    }

    private func removeHistory(_ entry: HistoryEntry) {
        if selection == .history(entry.outputPath) { selection = nil }
        queue.removeHistory(entry.outputPath)
    }

    private var activeItems: [QueueItem] { queue.items.filter { !$0.isFinished } }
    private var finishedItems: [QueueItem] { queue.items.filter { $0.isFinished } }

    // History minus entries already shown as finished queue items
    private var dedupedHistory: [HistoryEntry] {
        let livePaths = Set(finishedItems.compactMap { item -> String? in
            if case .done(let url) = item.status { return url.path }
            return nil
        })
        return queue.history.filter { !livePaths.contains($0.outputPath) }
    }

    private var todayHistory: [HistoryEntry] {
        dedupedHistory.filter { Calendar.current.isDateInToday($0.date) }
    }

    private var olderHistory: [HistoryEntry] {
        dedupedHistory.filter { !Calendar.current.isDateInToday($0.date) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.66)
            .foregroundStyle(DS.sectionHeader)
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack {
            Button {
                selection = nil
            } label: {
                Image(systemName: "house")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(selection == nil ? DS.accentIcon : DS.textTertiary)
            .help("Home — drop screen")
            Button {
                NSWorkspace.shared.open(AppSettings.current().outputFolder)
            } label: {
                Label("Output", systemImage: "folder")
                    .font(.system(size: 11.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.textTertiary)
            .padding(.leading, 10)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(DS.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Rectangle().fill(DS.hairline).frame(height: 1) }
    }
}

struct QueueRowView: View {
    let item: QueueItem
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            statusIcon.frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.filename)
                    .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(isSelected ? DS.accentMutedText : DS.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if case .failed = item.status {
                Text("Retry")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.errorText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? DS.selection : (hovering ? DS.rowHover : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var statusIcon: some View {
        switch item.status {
        case .waiting:
            Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(DS.textTertiary)
        case .awaitingConfirmation:
            Image(systemName: "exclamationmark.triangle").font(.system(size: 12)).foregroundStyle(DS.warning)
        case .converting:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .done:
            Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(DS.success)
        case .failed:
            Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(DS.error)
        case .cancelled:
            Image(systemName: "slash.circle").font(.system(size: 12)).foregroundStyle(DS.textQuaternary)
        }
    }

    private var subtitle: String? {
        switch item.status {
        case .waiting: return "Waiting"
        case .awaitingConfirmation: return "Needs confirmation"
        case .converting(let detail, let fraction):
            if let fraction { return "Converting · \(Int(fraction * 100))%" }
            return detail
        case .done:
            guard isSelected else { return nil }
            return item.duration.map { "Done · \($0)" } ?? "Done"
        case .failed: return nil
        case .cancelled: return "Cancelled"
        }
    }
}

struct HistoryRowView: View {
    let entry: HistoryEntry
    let isSelected: Bool
    var onRemove: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(DS.textTertiary)
                .frame(width: 14)
            Text(entry.name)
                .font(.system(size: 12.5, weight: isSelected ? .medium : .regular))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DS.textTertiary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(DS.pillBg))
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            } else {
                Text(entry.date, style: .relative)
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.textQuaternary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8)
            .fill(isSelected ? DS.selection : (hovering ? DS.rowHover : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Empty state (2a)

struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            }
            Text("Drop PDFs to convert")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
            Text("Clean, structured Markdown — German documents stay German")
                .font(.system(size: 12.5))
                .foregroundStyle(DS.textQuaternary)
            Button("Browse Files…") { browse() }
                .buttonStyle(PrimaryButtonStyle())
            DropStrip(text: "Or drop them anywhere in this window")
                .frame(width: 380, height: 90)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            ConversionQueue.shared.add(urls: panel.urls)
        }
    }
}

struct DropStrip: View {
    let text: String

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(DS.dropStripBg)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(DS.dropStripStroke, style: StrokeStyle(lineWidth: 1.5, dash: [6]))
            )
            .overlay(
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 14))
                        .foregroundStyle(DS.accentIcon)
                    Text(text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DS.accentMutedText)
                }
            )
    }
}

// MARK: - Item detail dispatcher

struct ItemDetailView: View {
    let item: QueueItem
    @EnvironmentObject var queue: ConversionQueue

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(DS.hairline).frame(height: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if case .done = item.status {} else {
                DropStrip(text: "Drop PDFs anywhere in the window")
                    .frame(height: 64)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if case .done = item.status {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DS.success)
            }
            Text(headerTitle)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let pill = item.pagePill {
                Text(pill)
                    .font(.system(size: 11))
                    .foregroundStyle(DS.textTertiary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DS.pillBg))
            }
            headerActions
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var headerTitle: String {
        if case .done(let url) = item.status { return url.lastPathComponent }
        return item.filename
    }

    @ViewBuilder private var headerActions: some View {
        switch item.status {
        case .converting, .waiting:
            Button("Cancel") { queue.cancel(item.id) }
                .buttonStyle(SecondaryButtonStyle())
        case .failed, .cancelled:
            Button("Remove") { queue.remove(item.id) }
                .buttonStyle(SecondaryButtonStyle())
        case .done(let url):
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            .buttonStyle(SecondaryButtonStyle())
            Button("Open Markdown") { NSWorkspace.shared.open(url) }
                .buttonStyle(PrimaryButtonStyle())
        case .awaitingConfirmation:
            EmptyView()
        }
    }

    @ViewBuilder private var content: some View {
        switch item.status {
        case .converting(let detail, let fraction):
            ConvertingView(item: item, detail: detail, fraction: fraction)
        case .awaitingConfirmation(let pageCount):
            ConfirmationView(item: item, pageCount: pageCount)
        case .failed(let message):
            FailureView(item: item, message: message)
        case .done(let url):
            SuccessView(outputURL: url, metadata: successMetadata)
        case .waiting:
            centeredInfo(icon: "clock", tint: DS.textTertiary,
                         title: "Waiting in queue",
                         message: "Converts automatically when the current document finishes.")
        case .cancelled:
            centeredInfo(icon: "slash.circle", tint: DS.textQuaternary,
                         title: "Cancelled",
                         message: "This file was skipped. Remove it or drop it again to reconvert.")
        }
    }

    private var successMetadata: String? {
        var parts: [String] = []
        // item.duration uses finishedAt; computing from Date() here inflated the
        // number whenever the success view was rendered again later.
        if let duration = item.duration {
            parts.append("Converted in \(duration)")
        }
        if let pill = item.pagePill { parts.append(pill) }
        parts.append(AppSettings.current().backend == .vertex
            ? AppSettings.vertexModel : AppSettings.current().model.replacingOccurrences(of: "google/", with: ""))
        return parts.joined(separator: " · ")
    }

    private func centeredInfo(icon: String, tint: Color, title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 32)).foregroundStyle(tint)
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.textPrimary)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Converting (2c)

struct ConvertingView: View {
    let item: QueueItem
    let detail: String
    let fraction: Double?

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            ProgressRing(fraction: fraction)
                .padding(5)
                .frame(width: 120, height: 120)
            VStack(spacing: 5) {
                Text(detail)
                    .font(.system(size: 13.5))
                    .foregroundStyle(DS.textSecondary)
                Text("Structured Markdown mirroring §1, §2, … · output stays German")
                    .font(.system(size: 11.5))
                    .foregroundStyle(DS.textQuaternary)
            }
            // TimelineView re-renders every second; without it the elapsed time was
            // computed once per status change and froze at "0:00".
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(metadata(now: context.date))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(DS.textQuaternary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func metadata(now: Date) -> String {
        let settings = AppSettings.current()
        let model = settings.backend == .vertex
            ? AppSettings.vertexModel : settings.model.replacingOccurrences(of: "google/", with: "")
        var parts = [model]
        if let started = item.startedAt {
            let secs = max(0, Int(now.timeIntervalSince(started)))
            parts.append("running \(secs / 60):\(String(format: "%02d", secs % 60))")
        }
        parts.append("→ \(settings.outputFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
        return parts.joined(separator: " · ")
    }
}

struct ProgressRing: View {
    let fraction: Double?
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(DS.pillBg, lineWidth: 6)
            if let fraction {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(DS.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.3), value: fraction)
                VStack(spacing: 2) {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 26, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DS.textPrimary)
                    Text("converting")
                        .font(.system(size: 10.5))
                        .foregroundStyle(DS.textQuaternary)
                }
            } else {
                Circle()
                    .trim(from: 0, to: 0.25)
                    .stroke(DS.accent, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
                Text("converting")
                    .font(.system(size: 10.5))
                    .foregroundStyle(DS.textQuaternary)
            }
        }
    }
}

// MARK: - Large-scan confirmation (2d)

struct ConfirmationView: View {
    let item: QueueItem
    let pageCount: Int
    @EnvironmentObject var queue: ConversionQueue

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(DS.warning.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26))
                    .foregroundStyle(DS.warning)
            }
            Text("\(pageCount) scanned pages")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
            Text("This document has no text layer, so every page is transcribed with OCR — one AI call per page. That's ~\(pageCount) calls for this file.")
                .font(.system(size: 12.5))
                .foregroundStyle(DS.textTertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Skip This File") { queue.confirmLargeFile(item.id, proceed: false) }
                    .buttonStyle(SecondaryButtonStyle())
                Button("Convert All \(pageCount) Pages") { queue.confirmLargeFile(item.id, proceed: true) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.top, 4)
            Text("The rest of the queue continues either way")
                .font(.system(size: 11))
                .foregroundStyle(DS.textQuaternary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Failure (2e)

struct FailureView: View {
    let item: QueueItem
    let message: String
    @EnvironmentObject var queue: ConversionQueue

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(DS.error.opacity(0.12))
                    .frame(width: 64, height: 64)
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(DS.error)
            }
            Text("Conversion failed")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
            Text(message)
                .font(.system(size: 12.5))
                .foregroundStyle(DS.errorText)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                if message.contains("OpenRouter") {
                    Button("Open openrouter.ai") {
                        NSWorkspace.shared.open(URL(string: "https://openrouter.ai/credits")!)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                Button("Retry") { queue.retry(item.id) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - History detail (success layout for past conversions)

struct HistoryDetailView: View {
    let outputURL: URL

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(DS.success)
                Text(outputURL.lastPathComponent)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
                .buttonStyle(SecondaryButtonStyle())
                Button("Open Markdown") { NSWorkspace.shared.open(outputURL) }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(.horizontal, 16)
            .frame(height: 52)
            Rectangle().fill(DS.hairline).frame(height: 1)
            SuccessView(outputURL: outputURL, metadata: nil)
        }
    }
}

// MARK: - Success (2f): markdown preview with Copy + Formatted/Markdown toggle

enum PreviewMode: String { case formatted, raw }

struct SuccessView: View {
    let outputURL: URL
    let metadata: String?
    @State private var rawContent = ""
    @State private var previewText = AttributedString("")
    @State private var formattedCache: AttributedString?
    @State private var rawCache: AttributedString?
    @State private var copied = false
    @State private var previewTruncated = false
    @AppStorage("previewMode") private var mode = PreviewMode.formatted.rawValue

    // A very large file rendered as one selectable AttributedString hangs the main
    // thread, so the on-screen preview is capped. Copy and Open Markdown use the full file.
    private static let previewLineCap = 600
    private static let previewCharCap = 60_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, metadata == nil ? 16 : 10)
            if let metadata {
                HStack(spacing: 16) {
                    ForEach(metadata.components(separatedBy: " · "), id: \.self) { part in
                        Text(part)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(DS.textQuaternary)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: loadPreview)
        .onChange(of: outputURL) { _, _ in loadPreview() }
        .onChange(of: mode) { _, _ in rebuild() }
    }

    // Non-scrolling toolbar strip on top of the card; content scrolls below the
    // hairline so it never collides with the controls.
    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                modeToggle
                Spacer(minLength: 8)
                copyButton
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Rectangle().fill(DS.hairline).frame(height: 1)
            ScrollView(showsIndicators: false) {
                Text(previewText)
                    .lineSpacing(mode == PreviewMode.raw.rawValue ? 5 : 4)
                    .textSelection(.enabled)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if previewTruncated {
                Rectangle().fill(DS.hairline).frame(height: 1)
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Long document, showing the first \(Self.previewLineCap) lines. Copy and Open Markdown use the full file.")
                }
                .font(.system(size: 11))
                .foregroundStyle(DS.textTertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(DS.previewBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.hairline, lineWidth: 0.5))
    }

    private var modeToggle: some View {
        HStack(spacing: 2) {
            modeSegment("Formatted", .formatted)
            modeSegment("Markdown", .raw)
        }
        .padding(2)
        .background(Capsule().fill(DS.pillBg))
        .overlay(Capsule().strokeBorder(DS.hairline, lineWidth: 0.5))
    }

    private func modeSegment(_ label: String, _ value: PreviewMode) -> some View {
        let selected = mode == value.rawValue
        return Button {
            mode = value.rawValue
        } label: {
            Text(label)
                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? DS.textPrimary : DS.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(selected ? DS.selection : Color.clear))
        }
        .buttonStyle(.plain)
        .help(value == .formatted ? "Rendered preview" : "Raw Markdown source")
    }

    private var copyButton: some View {
        Button {
            copyMarkdown()
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(DS.pillBg))
                .overlay(Capsule().strokeBorder(DS.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? DS.success : DS.textTertiary)
        .help("Copy the full Markdown to the clipboard")
    }

    private func loadPreview() {
        copied = false
        rawContent = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "Could not read \(outputURL.lastPathComponent)"
        formattedCache = nil
        rawCache = nil
        rebuild()
    }

    // Render each mode at most once per document; toggling just swaps the cache.
    private func rebuild() {
        let (slice, truncated) = Self.capForPreview(rawContent)
        previewTruncated = truncated
        if mode == PreviewMode.raw.rawValue {
            let text = rawCache ?? Self.renderRaw(slice)
            rawCache = text
            previewText = text
        } else {
            let text = formattedCache ?? Self.renderFormatted(slice)
            formattedCache = text
            previewText = text
        }
    }

    // Bound the rendered text so oversized documents can't hang the UI thread.
    private static func capForPreview(_ content: String) -> (String, Bool) {
        var slice = content
        var truncated = false
        if slice.count > previewCharCap {
            slice = String(slice.prefix(previewCharCap))
            truncated = true
        }
        let lines = slice.components(separatedBy: "\n")
        if lines.count > previewLineCap {
            slice = lines.prefix(previewLineCap).joined(separator: "\n")
            truncated = true
        }
        return (slice, truncated)
    }

    // Raw Markdown source: monospace, light heading tint (original preview).
    private static func renderRaw(_ content: String) -> AttributedString {
        var result = AttributedString()
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            var attr = AttributedString(i == 0 ? line : "\n" + line)
            if line.hasPrefix("# ") {
                attr.font = .system(size: 11.5, weight: .semibold, design: .monospaced)
                attr.foregroundColor = DS.textPrimary
            } else if line.hasPrefix("##") {
                attr.font = .system(size: 11.5, design: .monospaced)
                attr.foregroundColor = DS.mdHeading
            } else {
                attr.font = .system(size: 11.5, design: .monospaced)
                attr.foregroundColor = DS.monoBody
            }
            result += attr
        }
        return result
    }

    // Formatted: proportional type with heading hierarchy, lists, inline bold.
    // Tables and fenced code fall back to monospace so columns/indentation align.
    private static func renderFormatted(_ content: String) -> AttributedString {
        var result = AttributedString()
        var inFence = false
        for (i, line) in content.components(separatedBy: "\n").enumerated() {
            if i > 0 { result += AttributedString("\n") }
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {          // code fence marker: toggle, hide the ``` line
                inFence.toggle()
            } else if inFence {
                result += mono(line)
            } else if trimmed.isEmpty {
                continue                            // blank line already carried by the \n
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                result += horizontalRule()
            } else if trimmed.hasPrefix("|") {      // table row: monospace keeps columns aligned
                result += mono(line)
            } else if let (level, rest) = headingLevel(line) {
                let style = headingStyle(level)
                result += inline(rest, style.font, style.color)
            } else if let (number, rest) = orderedItem(line) {
                var marker = AttributedString(number + ".  ")
                marker.font = .system(size: 13, weight: .semibold)
                marker.foregroundColor = DS.textTertiary
                result += marker
                result += inline(rest, .system(size: 13), DS.textSecondary)
            } else if let (indent, rest) = bulletItem(line) {
                var dot = AttributedString(String(repeating: " ", count: indent) + "•  ")
                dot.font = .system(size: 13)
                dot.foregroundColor = DS.textTertiary
                result += dot
                result += inline(rest, .system(size: 13), DS.textSecondary)
            } else if trimmed.hasPrefix("> ") {
                result += inline(String(trimmed.dropFirst(2)), .system(size: 13).italic(), DS.textTertiary)
            } else {
                result += inline(line, .system(size: 13), DS.textSecondary)
            }
        }
        return result
    }

    // Splits a line on ** and bolds the enclosed spans. An unbalanced ** (odd
    // delimiter count) is treated as literal text rather than bolding to line end.
    private static func inline(_ text: String, _ font: Font, _ color: Color) -> AttributedString {
        let parts = text.components(separatedBy: "**")
        if parts.count.isMultiple(of: 2) {          // even parts == odd delimiters == unbalanced
            return styled(text, font, color)
        }
        var out = AttributedString()
        for (idx, segment) in parts.enumerated() {
            if segment.isEmpty { continue }
            out += styled(segment, idx.isMultiple(of: 2) ? font : font.bold(), color)
        }
        return out.characters.isEmpty ? styled(text, font, color) : out
    }

    private static func styled(_ text: String, _ font: Font, _ color: Color) -> AttributedString {
        var a = AttributedString(text)
        a.font = font
        a.foregroundColor = color
        return a
    }

    private static func mono(_ text: String) -> AttributedString {
        styled(text, .system(size: 11.5, design: .monospaced), DS.monoBody)
    }

    private static func horizontalRule() -> AttributedString {
        styled("──────────────────────", .system(size: 11), DS.textQuaternary)
    }

    private static func headingStyle(_ level: Int) -> (font: Font, color: Color) {
        switch level {
        case 1: return (.system(size: 20, weight: .bold), DS.textPrimary)
        case 2: return (.system(size: 15, weight: .semibold), DS.mdHeading)
        case 3: return (.system(size: 12.5, weight: .semibold), DS.textSecondary)
        default: return (.system(size: 12, weight: .semibold), DS.textTertiary)
        }
    }

    // ATX heading of any level 1...6: N leading '#' then a space.
    private static func headingLevel(_ line: String) -> (Int, String)? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1 } else { break }
        }
        guard count >= 1, count <= 6 else { return nil }
        let afterHashes = line.index(line.startIndex, offsetBy: count)
        guard afterHashes < line.endIndex, line[afterHashes] == " " else { return nil }
        return (count, String(line[line.index(after: afterHashes)...]))
    }

    // Ordered-list item: optional indent, digits, then ". ".
    private static func orderedItem(_ line: String) -> (String, String)? {
        let stripped = line.drop(while: { $0 == " " })
        var digits = ""
        var rest = stripped
        for ch in stripped {
            if ch.isNumber { digits.append(ch); rest = rest.dropFirst() } else { break }
        }
        guard !digits.isEmpty, rest.hasPrefix(". ") else { return nil }
        return (digits, String(rest.dropFirst(2)))
    }

    // Bullet item with leading-whitespace tolerance; returns the indent width.
    private static func bulletItem(_ line: String) -> (Int, String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        let stripped = line.drop(while: { $0 == " " })
        guard stripped.hasPrefix("- ") || stripped.hasPrefix("* ") else { return nil }
        return (indent, String(stripped.dropFirst(2)))
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawContent, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
