import Foundation

// Failure forensics: raw model output that could not be used is dumped here so a
// failed conversion is diagnosable after the fact (the UI only shows one line).
// Files are tiny in number (written only on rare failure paths) and plain text.
enum DebugLog {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/PDFConverter", isDirectory: true)

    static func dump(_ name: String, _ content: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? content.write(to: dir.appendingPathComponent("\(stamp)-\(name).txt"),
                           atomically: true, encoding: .utf8)
    }
}
