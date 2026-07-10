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
                            HistoryRowView(entry: entry, isSelected: selection == .history(entry.outputPath))
                                .onTapGesture { toggle(.history(entry.outputPath)) }
                        }
                    }
                    if !olderHistory.isEmpty {
                        sectionHeader("Recent").padding(.top, 14)
                        ForEach(olderHistory) { entry in
                            HistoryRowView(entry: entry, isSelected: selection == .history(entry.outputPath))
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
            Text(entry.date, style: .relative)
                .font(.system(size: 10.5))
                .foregroundStyle(DS.textQuaternary)
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
        if let started = item.startedAt {
            let secs = Int(Date().timeIntervalSince(started))
            parts.append("Converted in \(secs / 60):\(String(format: "%02d", secs % 60))")
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
            Text(metadata)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(DS.textQuaternary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var metadata: String {
        let settings = AppSettings.current()
        let model = settings.backend == .vertex
            ? AppSettings.vertexModel : settings.model.replacingOccurrences(of: "google/", with: "")
        var parts = [model]
        if let started = item.startedAt {
            let secs = Int(Date().timeIntervalSince(started))
            parts.append("started \(secs / 60):\(String(format: "%02d", secs % 60)) ago")
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

// MARK: - Success (2f) — markdown preview with Copy

struct SuccessView: View {
    let outputURL: URL
    let metadata: String?
    @State private var previewLines: [String] = []
    @State private var copied = false

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
    }

    private var preview: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(previewLines.enumerated()), id: \.offset) { _, line in
                    styledLine(line)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(DS.previewBg))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.hairline, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            Button {
                copyMarkdown()
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DS.pillBg))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? DS.success : DS.textTertiary)
            .padding(10)
            .help("Copy the full Markdown to the clipboard")
        }
    }

    @ViewBuilder private func styledLine(_ line: String) -> some View {
        if line.isEmpty {
            Text(" ").font(.system(size: 11.5, design: .monospaced))
        } else if line.hasPrefix("# ") {
            Text(line)
                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(DS.textPrimary)
                .lineSpacing(5)
        } else if line.hasPrefix("##") {
            Text(line)
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .foregroundStyle(DS.mdHeading)
                .lineSpacing(5)
        } else {
            Text(line)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(DS.monoBody)
                .lineSpacing(5)
        }
    }

    private func loadPreview() {
        copied = false
        let content = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? "Could not read \(outputURL.lastPathComponent)"
        let lines: [String] = content.components(separatedBy: "\n")
        previewLines = Array(lines.prefix(24))
    }

    private func copyMarkdown() {
        guard let content = try? String(contentsOf: outputURL, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
    }
}
