import Foundation
import PDFKit
import AppKit

enum ConversionError: LocalizedError {
    case noAPIKey
    case unreadablePDF
    case encryptedPDF
    case emptyPDF
    case network(String)
    case apiError(Int, String)
    case emptyResponse
    case renderFailed(Int)
    case outputWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key set. Open Settings and paste your OpenRouter key."
        case .unreadablePDF:
            return "File could not be opened as a PDF."
        case .encryptedPDF:
            return "File is password-protected."
        case .emptyPDF:
            return "PDF has no pages."
        case .network(let detail):
            return "Network problem: \(detail). Check your internet connection."
        case .apiError(let code, let detail):
            return "OpenRouter error \(code): \(detail)"
        case .emptyResponse:
            return "The model returned an empty response."
        case .renderFailed(let page):
            return "Could not render page \(page) as an image."
        case .outputWriteFailed(let detail):
            return "Could not write output file: \(detail)"
        }
    }
}

struct ConversionResult {
    let outputURL: URL
}

// Ports the pipeline from parse_contract.py: text-layer PDFs get one structured
// JSON call; scanned PDFs get per-page Gemini Vision OCR.
struct Converter {
    let apiKey: String
    let model: String
    let userPrompt: String
    let outputFolder: URL

    private static let apiURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

    struct PDFInfo {
        let pageCount: Int
        let hasTextLayer: Bool
    }

    static func inspect(url: URL) throws -> PDFInfo {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadablePDF }
        if doc.isEncrypted && doc.isLocked { throw ConversionError.encryptedPDF }
        guard doc.pageCount > 0 else { throw ConversionError.emptyPDF }
        var hasText = false
        for i in 0..<doc.pageCount {
            if let text = doc.page(at: i)?.string,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hasText = true
                break
            }
        }
        return PDFInfo(pageCount: doc.pageCount, hasTextLayer: hasText)
    }

    func convert(url: URL, progress: @escaping @Sendable (String, Double?) -> Void) async throws -> ConversionResult {
        guard let doc = PDFDocument(url: url) else { throw ConversionError.unreadablePDF }
        if doc.isEncrypted && doc.isLocked { throw ConversionError.encryptedPDF }
        let pageCount = doc.pageCount
        guard pageCount > 0 else { throw ConversionError.emptyPDF }

        let fullText = extractText(doc: doc)
        let markdown: String

        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            markdown = try await convertScanned(doc: doc, sourceName: url.deletingPathExtension().lastPathComponent, progress: progress)
        } else {
            progress("Analyzing document…", nil)
            let userContent = "Vollständiger Dokumenttext (\(pageCount) Seiten):\n\n\(fullText)\n\n\(userPrompt)"
            let response = try await chat(system: Prompts.structuredSystem, userText: userContent)
            try Task.checkCancellation()
            let json = Self.parseJSON(response)
            markdown = MarkdownRenderer.render(json, sourceName: url.deletingPathExtension().lastPathComponent)
        }

        progress("Saving…", nil)
        let outputURL = try save(markdown: markdown, sourceURL: url)
        return ConversionResult(outputURL: outputURL)
    }

    // MARK: - Text extraction

    private func extractText(doc: PDFDocument) -> String {
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            guard let text = doc.page(at: i)?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            parts.append("--- Seite \(i + 1) von \(doc.pageCount) ---\n\(text)")
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: - Scanned path (per-page Gemini Vision OCR)

    private func convertScanned(doc: PDFDocument, sourceName: String, progress: @escaping @Sendable (String, Double?) -> Void) async throws -> String {
        var pagesMD: [String] = []
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            progress("OCR page \(i + 1)/\(doc.pageCount)", Double(i) / Double(doc.pageCount))
            guard let page = doc.page(at: i), let png = Self.renderPNG(page: page) else {
                throw ConversionError.renderFailed(i + 1)
            }
            let dataURL = "data:image/png;base64,\(png.base64EncodedString())"
            let pageMD = try await chat(system: Prompts.visionSystem, userText: userPrompt, imageDataURLs: [dataURL])
            pagesMD.append("## Seite \(i + 1)\n\n\(pageMD.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return "# \(sourceName)\n\n" + pagesMD.joined(separator: "\n\n---\n\n")
    }

    static func renderPNG(page: PDFPage, dpi: CGFloat = 300) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = dpi / 72.0
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff)
        else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - API

    private func chat(system: String, userText: String, imageDataURLs: [String] = [], maxAttempts: Int = 3) async throws -> String {
        guard !apiKey.isEmpty else { throw ConversionError.noAPIKey }

        let userContent: Any
        if imageDataURLs.isEmpty {
            userContent = userText
        } else {
            var parts: [[String: Any]] = [["type": "text", "text": userText]]
            for url in imageDataURLs {
                parts.append(["type": "image_url", "image_url": ["url": url]])
            }
            userContent = parts
        }

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": userContent],
            ],
            "max_tokens": 32768,
        ]

        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 600

        var lastError: Error = ConversionError.network("unknown")
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ConversionError.network("no HTTP response")
                }
                guard http.statusCode == 200 else {
                    let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                    // 4xx won't get better on retry; 5xx / 429 might
                    if http.statusCode >= 500 || http.statusCode == 429, attempt < maxAttempts {
                        throw RetryableError(underlying: ConversionError.apiError(http.statusCode, String(detail)))
                    }
                    throw ConversionError.apiError(http.statusCode, String(detail))
                }
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any],
                      let content = message["content"] as? String,
                      !content.isEmpty
                else { throw ConversionError.emptyResponse }
                return content
            } catch let error as RetryableError {
                lastError = error.underlying
            } catch let error as URLError where error.code != .cancelled {
                lastError = ConversionError.network(error.localizedDescription)
            } catch {
                throw error
            }
            if attempt < maxAttempts {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 3_000_000_000)
            }
        }
        throw lastError
    }

    private struct RetryableError: Error {
        let underlying: Error
    }

    // MARK: - Output

    static func parseJSON(_ text: String) -> [String: Any] {
        func attempt(_ s: String) -> [String: Any]? {
            guard let data = s.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
        if let obj = attempt(text) { return obj }
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("```json") { clean = String(clean.dropFirst(7)) }
        if clean.hasPrefix("```") { clean = String(clean.dropFirst(3)) }
        if clean.hasSuffix("```") { clean = String(clean.dropLast(3)) }
        clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        if let obj = attempt(clean) { return obj }
        return ["raw_response": text]
    }

    private func save(markdown: String, sourceURL: URL) throws -> URL {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: outputFolder, withIntermediateDirectories: true)
            let name = sourceURL.deletingPathExtension().lastPathComponent + ".md"
            let outputURL = outputFolder.appendingPathComponent(name)
            try markdown.write(to: outputURL, atomically: true, encoding: .utf8)
            return outputURL
        } catch {
            throw ConversionError.outputWriteFailed(error.localizedDescription)
        }
    }
}
