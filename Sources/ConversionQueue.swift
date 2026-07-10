import Foundation
import SwiftUI

struct QueueItem: Identifiable, Equatable {
    enum Status: Equatable {
        case waiting
        case awaitingConfirmation(pageCount: Int)   // large scanned file, cost guard
        case converting(detail: String, fraction: Double?)
        case done(URL)
        case failed(String)
        case cancelled

        var isActive: Bool {
            if case .converting = self { return true }
            return false
        }
    }

    let id = UUID()
    let url: URL
    var status: Status = .waiting

    var filename: String { url.lastPathComponent }
}

struct HistoryEntry: Codable, Identifiable {
    var id: String { outputPath }
    let name: String
    let outputPath: String
    let date: Date
}

@MainActor
final class ConversionQueue: ObservableObject {
    static let shared = ConversionQueue()

    @Published var items: [QueueItem] = []
    @Published private(set) var history: [HistoryEntry] = []

    private var currentTask: Task<Void, Never>?
    private var currentItemID: UUID?

    // Scanned PDFs above this page count cost one Vision call per page; ask first.
    static let largeFileThreshold = 100

    private init() {
        loadHistory()
    }

    var isBusy: Bool {
        items.contains { $0.status.isActive || $0.status == .waiting }
    }

    // MARK: - Public actions

    func add(urls: [URL]) {
        let pdfs = urls.filter { $0.pathExtension.lowercased() == "pdf" }
        for url in pdfs {
            // Skip exact duplicates that are still pending
            if items.contains(where: { $0.url == url && ($0.status == .waiting || $0.status.isActive) }) { continue }
            items.append(QueueItem(url: url))
        }
        processNextIfIdle()
    }

    func cancel(_ id: UUID) {
        if currentItemID == id {
            currentTask?.cancel()
        } else if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].status = .cancelled
        }
    }

    func retry(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .waiting
        processNextIfIdle()
    }

    func confirmLargeFile(_ id: UUID, proceed: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if proceed {
            startConversion(itemID: id, skipLargeFileCheck: true)
        } else {
            items[idx].status = .cancelled
            processNextIfIdle()
        }
    }

    func clearFinished() {
        items.removeAll { Self.isFinished($0.status) }
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id && Self.isFinished($0.status) }
    }

    static func isFinished(_ status: QueueItem.Status) -> Bool {
        switch status {
        case .done, .cancelled, .failed: return true
        case .waiting, .awaitingConfirmation, .converting: return false
        }
    }

    // MARK: - Processing

    private func processNextIfIdle() {
        guard currentItemID == nil,
              let next = items.first(where: { $0.status == .waiting })
        else { return }
        startConversion(itemID: next.id, skipLargeFileCheck: false)
    }

    private func startConversion(itemID: UUID, skipLargeFileCheck: Bool) {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return }
        let url = items[idx].url

        // Cost guard: scanned + huge -> ask before spending one API call per page
        if !skipLargeFileCheck {
            do {
                let info = try Converter.inspect(url: url)
                if !info.hasTextLayer && info.pageCount > Self.largeFileThreshold {
                    items[idx].status = .awaitingConfirmation(pageCount: info.pageCount)
                    processNextIfIdle()
                    return
                }
            } catch {
                items[idx].status = .failed(error.localizedDescription)
                processNextIfIdle()
                return
            }
        }

        let settings = AppSettings.current()
        guard let apiKey = Keychain.readAPIKey(), !apiKey.isEmpty else {
            items[idx].status = .failed(ConversionError.noAPIKey.localizedDescription)
            processNextIfIdle()
            return
        }

        currentItemID = itemID
        items[idx].status = .converting(detail: "Starting…", fraction: nil)

        let converter = Converter(
            apiKey: apiKey,
            model: settings.model,
            userPrompt: settings.userPrompt,
            outputFolder: settings.outputFolder
        )

        currentTask = Task {
            do {
                let result = try await converter.convert(url: url) { detail, fraction in
                    Task { @MainActor in
                        ConversionQueue.shared.updateStatus(itemID, .converting(detail: detail, fraction: fraction))
                    }
                }
                self.updateStatus(itemID, .done(result.outputURL))
                self.addToHistory(name: url.lastPathComponent, outputURL: result.outputURL)
                self.notify(title: "Converted", body: "Saved: \(result.outputURL.lastPathComponent)")
            } catch is CancellationError {
                self.updateStatus(itemID, .cancelled)
            } catch let error as URLError where error.code == .cancelled {
                self.updateStatus(itemID, .cancelled)
            } catch {
                self.updateStatus(itemID, .failed(error.localizedDescription))
                self.notify(title: "Conversion failed", body: "\(url.lastPathComponent): \(error.localizedDescription)")
            }
            self.currentItemID = nil
            self.currentTask = nil
            self.processNextIfIdle()
        }
    }

    private func updateStatus(_ id: UUID, _ status: QueueItem.Status) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = status
    }

    // MARK: - History

    private static let historyKey = "conversionHistory"

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let entries = try? JSONDecoder().decode([HistoryEntry].self, from: data)
        else { return }
        history = entries
    }

    private func addToHistory(name: String, outputURL: URL) {
        history.removeAll { $0.outputPath == outputURL.path }
        history.insert(HistoryEntry(name: name, outputPath: outputURL.path, date: Date()), at: 0)
        history = Array(history.prefix(8))
        if let data = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(data, forKey: Self.historyKey)
        }
    }

    // MARK: - Notifications

    private func notify(title: String, body: String) {
        // Deliver only when the app is in the background; the window shows state otherwise.
        guard !NSApp.isActive else { return }
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.deliver(notification)
    }
}
