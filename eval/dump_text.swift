import Foundation
import PDFKit

// Dumps a PDF's text layer exactly the way Converter.extractPages feeds it to the
// model (same page markers, same empty-page skipping), so eval/score.py measures
// against the input the app actually saw.
//
// Usage: swiftc -o /tmp/dump_text eval/dump_text.swift && /tmp/dump_text <file.pdf>

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: dump_text <file.pdf>\n".utf8))
    exit(2)
}
guard let doc = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    FileHandle.standardError.write(Data("unreadable PDF\n".utf8))
    exit(1)
}
var parts: [String] = []
for i in 0..<doc.pageCount {
    guard let text = doc.page(at: i)?.string,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { continue }
    parts.append("--- Seite \(i + 1) von \(doc.pageCount) ---\n\(text)")
}
print(parts.joined(separator: "\n\n"))
