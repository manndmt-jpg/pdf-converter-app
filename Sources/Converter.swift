import Foundation
import PDFKit
import AppKit

enum ConversionError: LocalizedError {
    case noAPIKey
    case vertexNotConfigured
    case vertexAuthFailed
    case unreadablePDF
    case encryptedPDF
    case emptyPDF
    case network(String)
    case apiError(Int, String)
    case emptyResponse
    case responseTruncated
    case renderFailed(Int)
    case outputWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key set. Open Settings and paste your OpenRouter key."
        case .vertexNotConfigured:
            return "Vertex AI is not configured. Open Settings and add project ID and credentials."
        case .vertexAuthFailed:
            return "Google token refresh failed. Re-run 'gcloud auth application-default login' and paste the new credentials JSON in Settings."
        case .unreadablePDF:
            return "File could not be opened as a PDF."
        case .encryptedPDF:
            return "File is password-protected."
        case .emptyPDF:
            return "PDF has no pages."
        case .network(let detail):
            return "Network problem: \(detail). Check your internet connection."
        case .apiError(let code, let detail):
            // Neutral wording: this fires for both OpenRouter and Vertex backends.
            return code > 0 ? "API error \(code): \(detail)" : "AI provider error: \(detail)"
        case .emptyResponse:
            return "The model returned an empty response."
        case .responseTruncated:
            return "The AI returned a cut-off or incomplete answer for this document, so the result could not be assembled. Converting the same file again usually works; if it keeps failing, the PDF is unusually dense."
        case .renderFailed(let page):
            return "Could not render page \(page) as an image."
        case .outputWriteFailed(let detail):
            return "Could not write output file: \(detail)"
        }
    }
}

struct ConversionResult {
    let outputURL: URL
    // Non-fatal quality issue the user should know about (e.g. clause numbers
    // present in the PDF but absent from the answer). The file is still saved.
    let warning: String?
}

// Ports the pipeline from parse_contract.py: text-layer PDFs get one structured
// JSON call; scanned PDFs get per-page Gemini Vision OCR.
// Backends: OpenRouter (chat/completions) or Vertex AI EU (generateContent).
struct Converter {
    let backend: Backend
    let apiKey: String            // OpenRouter key; unused for Vertex
    let model: String
    let userPrompt: String
    let outputFolder: URL
    let vertexProjectId: String
    let vertexRegion: String
    let vertexCredentials: VertexCredentials?

    private static let openRouterURL = URL(string: "https://openrouter.ai/api/v1/chat/completions")!

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

        let pages = extractPages(doc: doc)
        let sourceName = url.deletingPathExtension().lastPathComponent
        let result: (markdown: String, warning: String?)

        if pages.isEmpty {
            result = (try await convertScanned(doc: doc, sourceName: sourceName, progress: progress), nil)
        } else {
            do {
                result = try await convertTextLayer(pages: pages, pageCount: pageCount, doc: doc, sourceName: sourceName, forceSplit: false, progress: progress)
            } catch ConversionError.responseTruncated where pages.count > 1 {
                // The one-pass answer would not fit or never came back as valid JSON
                // even after re-asks. Halve the request: smaller answers stay far from
                // the token cap and are much less likely to contain broken JSON.
                result = try await convertTextLayer(pages: pages, pageCount: pageCount, doc: doc, sourceName: sourceName, forceSplit: true, progress: progress)
            }
        }

        progress("Saving…", nil)
        let outputURL = try save(markdown: result.markdown, sourceURL: url)
        return ConversionResult(outputURL: outputURL, warning: result.warning)
    }

    // MARK: - Text-layer path (structured JSON, chunked when large)

    private func convertTextLayer(pages: [String], pageCount: Int, doc: PDFDocument, sourceName: String, forceSplit: Bool, progress: @escaping @Sendable (String, Double?) -> Void) async throws -> (markdown: String, warning: String?) {
        let totalChars = pages.reduce(0) { $0 + $1.count }
        let maxChars = forceSplit
            ? min(DocumentChunker.maxChunkChars / 2, totalChars / 2)
            : DocumentChunker.maxChunkChars
        let chunks = DocumentChunker.chunk(pages: pages, maxChars: maxChars)
        var parsed: [[String: Any]] = []
        var openSection: String?
        for (i, chunkText) in chunks.enumerated() {
            if chunks.count == 1 {
                progress("Converting the whole document in one AI call (takes a few minutes)", nil)
            } else {
                progress("Converting part \(i + 1)/\(chunks.count)", Double(i) / Double(chunks.count))
            }
            var userContent = "Vollständiger Dokumenttext (\(pageCount) Seiten):\n\n\(chunkText)\n\n\(userPrompt)"
            if chunks.count > 1 {
                var hint = "Hinweis: Dies ist Teil \(i + 1) von \(chunks.count) eines längeren Dokuments. Extrahiere nur die Abschnitte, die in diesem Teil enthalten sind."
                // A chunk usually starts mid-section (its heading sits in the previous
                // chunk). Give the model that heading so the continuation comes back
                // under the SAME id and the merge fold can re-join the halves.
                if let openSection {
                    hint += " Der vorherige Teil endete innerhalb des Abschnitts \(openSection). NUR falls dieser Teil mit der Fortsetzung dieses Abschnitts beginnt (Text ohne eigene Abschnittsüberschrift), gib diese Fortsetzung als ersten Abschnitt mit exakt derselben id und demselben Titel aus. Beginnt dieser Teil dagegen mit einer neuen Abschnittsüberschrift, verwende deren eigene Nummerierung."
                }
                userContent = "Dokumenttext, Teil \(i + 1) von \(chunks.count) (insgesamt \(pageCount) Seiten):\n\n\(chunkText)\n\n\(userPrompt)\n\n\(hint)"
            }
            var json: [String: Any] = [:]
            var parseFailures = 0
            while true {
                let response = try await chat(system: Prompts.structuredSystem, userText: userContent, maxAttempts: 5)
                try Task.checkCancellation()
                json = Self.parseJSON(response)
                if json["raw_response"] == nil { break }
                // The answer arrived complete (chat() already screened out mid-stream
                // errors and token-cap truncation) but is not valid JSON. Sampling is
                // nondeterministic, so one full re-ask usually yields a clean answer.
                parseFailures += 1
                DebugLog.dump("unparseable-part\(i + 1)-try\(parseFailures)", response)
                guard parseFailures < 2 else { throw ConversionError.responseTruncated }
                progress(chunks.count == 1
                    ? "Answer was not machine-readable, asking again"
                    : "Part \(i + 1)/\(chunks.count): answer was not machine-readable, asking again",
                    chunks.count == 1 ? nil : Double(i) / Double(chunks.count))
            }
            parsed.append(json)
            if let last = (json["sections"] as? [[String: Any]])?.last {
                let label = "\((last["id"] as? String) ?? "") \((last["title"] as? String) ?? "")"
                    .trimmingCharacters(in: .whitespaces)
                // A header-less trailing section means we are still inside the
                // previously known section, so keep that hint rather than clearing it.
                if !label.isEmpty {
                    openSection = "\"\(label)\""
                }
            }
        }
        let merged = parsed.count == 1 ? parsed[0] : DocumentChunker.merge(parsed)
        var markdown = MarkdownRenderer.render(merged, sourceName: sourceName)
        // The prompt forbids summarizing, so a faithful answer is roughly as long as
        // the source (measured: 126K chars rendered from 125.7K source). A drastically
        // shorter answer means the model silently skipped content (observed on Vertex
        // with thinking on: 20K of 126K). Reject it so the split-fallback retries.
        if markdown.count < totalChars * 2 / 5 {
            DebugLog.dump("incomplete-answer", markdown)
            throw ConversionError.responseTruncated
        }

        // Clause audit: an answer can pass the length guard and still be missing a
        // small run of clauses. Two observed causes: nondeterministic drops
        // (6.15.2.4-6.15.2.6 gone from an otherwise complete answer) and misbound
        // numbering on two-column PDFs whose text layer decouples clause numbers
        // from their paragraphs (8.6/8.7 fused and shifted). Text-only re-asks
        // reproduce the bad guess, and a full re-ask with images attached STILL
        // misbound in a live test. What works (live-verified): a small, focused
        // extraction of ONLY the affected numbered run from the page images, then
        // splicing that run into the answer by content match. Whatever is still
        // missing afterwards is surfaced to the user instead of silently shipped.
        let sourceText = chunks.joined(separator: "\n\n")
        var missing = ClauseAudit.missingIds(source: sourceText, answer: markdown)
        var currentMerged = merged
        if !missing.isEmpty, missing.count <= ClauseAudit.retryThreshold {
            progress("Numbering unclear around clause \(missing[0]), re-reading the affected pages", nil)
            let runs = Dictionary(grouping: missing) { $0.split(separator: ".").first.map(String.init) ?? $0 }
            for (prefix, runMissing) in runs.sorted(by: { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }).prefix(3) {
                let images = ClauseAudit.pdfPageNumbers(missing: runMissing, pageTexts: pages)
                    .compactMap { doc.page(at: $0 - 1) }
                    .compactMap { Self.renderPNG(page: $0, dpi: 200) }
                    .map { $0.base64EncodedString() }
                guard !images.isEmpty else {
                    DebugLog.dump("audit-images-empty-\(prefix)", runMissing.joined(separator: ", "))
                    continue
                }
                let ask = """
                Auf den angehängten Seitenbildern steht die Ziffer\(runMissing.count == 1 ? "" : "n") \(runMissing.joined(separator: ", ")) (Hauptziffer \(prefix)). \
                Transkribiere alle AUF DEN BILDERN SICHTBAREN Ziffern der Hauptziffer \(prefix) (einschließlich \(runMissing.joined(separator: ", "))), jede mit vollem Wortlaut, in der Reihenfolge der Bilder. \
                Lasse Ziffern weg, die nicht auf den Bildern stehen. \
                Nicht nummerierte Absätze gehören zum Inhalt der davorstehenden Ziffer. \
                Format: {"subsections": [{"id": "\(prefix).1", "content": "..."}]}
                """
                do {
                    let response = try await chat(system: Prompts.clauseRunSystem, userText: ask, pngBase64Images: images, maxAttempts: 3)
                    try Task.checkCancellation()
                    let json = Self.parseJSON(response)
                    guard let rawRun = json["subsections"] as? [[String: Any]],
                          let run = ClauseAudit.sanitizeRun(rawRun, prefix: prefix, mustContain: runMissing) else {
                        DebugLog.dump("audit-run-unusable-\(prefix)", response)
                        continue
                    }
                    let runIds = ClauseAudit.ids(in: run.compactMap { $0["id"] as? String }.joined(separator: " "))
                    guard runMissing.allSatisfy({ runIds.contains($0) }) else {
                        DebugLog.dump("audit-run-incomplete-\(prefix)", response)
                        continue
                    }
                    if let sections = currentMerged["sections"] as? [[String: Any]],
                       let spliced = ClauseAudit.splice(run: run, intoSections: sections, runPrefix: prefix) {
                        var candidate = currentMerged
                        candidate["sections"] = spliced
                        let newMarkdown = MarkdownRenderer.render(candidate, sourceName: sourceName)
                        let newMissing = ClauseAudit.missingIds(source: sourceText, answer: newMarkdown)
                        // Adopt each run's splice on its own merits: one failed
                        // splice must not poison another run's successful fix, and
                        // the length guard keeps a shrunken answer from winning.
                        if newMissing.count < missing.count, newMarkdown.count >= totalChars * 2 / 5 {
                            currentMerged = candidate
                            markdown = newMarkdown
                            missing = newMissing
                        } else {
                            DebugLog.dump("audit-splice-rejected-\(prefix)", newMarkdown)
                        }
                    } else {
                        // No confident window in the answer for this run: keep the
                        // original and warn. The dump preserves the vision answer
                        // for diagnosis (this path used to exit without a trace).
                        DebugLog.dump("audit-splice-nil-\(prefix)", response)
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw error
                } catch {
                    // The first answer is already usable; a failed audit retry must
                    // not sink the conversion.
                    DebugLog.dump("audit-run-failed-\(prefix)", String(describing: error))
                }
            }
        }
        if !missing.isEmpty {
            DebugLog.dump("clause-audit-missing", missing.joined(separator: ", "))
        }
        // The reverse audit: numbering the answer carries that the PDF does not.
        // Warn only — mutating content on suspicion is worse than flagging it.
        let invented = ClauseAudit.inventedIds(source: sourceText, answer: markdown)
        let bare = ClauseAudit.bareNumberedSections(
            sections: (currentMerged["sections"] as? [[String: Any]]) ?? [], source: sourceText)
        if !invented.isEmpty || !bare.isEmpty {
            DebugLog.dump("clause-audit-invented",
                          "invented: \(invented.joined(separator: ", ")) | bare-numbered sections: \(bare.joined(separator: ", "))")
        }
        return (markdown, ClauseAudit.warning(missing: missing, invented: invented,
                                              bareSections: bare, pageTexts: pages))
    }

    // MARK: - Text extraction

    private func extractPages(doc: PDFDocument) -> [String] {
        var parts: [String] = []
        for i in 0..<doc.pageCount {
            guard let text = doc.page(at: i)?.string,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { continue }
            parts.append("--- Seite \(i + 1) von \(doc.pageCount) ---\n\(text)")
        }
        return parts
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
            let pageMD = try await chat(system: Prompts.visionSystem, userText: userPrompt, pngBase64Images: [png.base64EncodedString()], allowTruncated: true)
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

    // Fallback for Gemini capacity storms (rate limits, provider failures) on the
    // OpenRouter backend: a different model family draws from a different capacity
    // pool. Text-only; the vision/OCR path stays on Gemini. Verified against the
    // structured prompt on a full 17-page doc (returns fenced JSON; parseJSON strips it).
    private static let fallbackTextModel = "mistralai/mistral-large-2512"

    private static func isWorthFallback(_ error: Error) -> Bool {
        switch error {
        case ConversionError.emptyResponse:
            return true
        case ConversionError.apiError(let code, _):
            return code == 429 || code >= 500 || code == 0
        default:
            return false
        }
    }

    private func chat(system: String, userText: String, pngBase64Images: [String] = [], maxAttempts: Int = 3, allowTruncated: Bool = false) async throws -> String {
        do {
            return try await chatLoop(model: model, system: system, userText: userText, pngBase64Images: pngBase64Images, maxAttempts: maxAttempts, allowTruncated: allowTruncated)
        } catch let error where backend == .openrouter && pngBase64Images.isEmpty
            && model != Self.fallbackTextModel && Self.isWorthFallback(error) {
            return try await chatLoop(model: Self.fallbackTextModel, system: system, userText: userText, pngBase64Images: [], maxAttempts: 2, allowTruncated: allowTruncated)
        }
    }

    private func chatLoop(model: String, system: String, userText: String, pngBase64Images: [String], maxAttempts: Int, allowTruncated: Bool) async throws -> String {
        var lastError: Error = ConversionError.network("unknown")
        var rateLimited = false
        for attempt in 1...maxAttempts {
            try Task.checkCancellation()
            do {
                let request = try await buildRequest(model: model, system: system, userText: userText, pngBase64Images: pngBase64Images)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ConversionError.network("no HTTP response")
                }
                guard http.statusCode == 200 else {
                    let detail = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
                    // 4xx won't get better on retry; 5xx / 429 might
                    if http.statusCode >= 500 || http.statusCode == 429, attempt < maxAttempts {
                        rateLimited = rateLimited || http.statusCode == 429
                        throw RetryableError(underlying: ConversionError.apiError(http.statusCode, String(detail)))
                    }
                    throw ConversionError.apiError(http.statusCode, String(detail))
                }
                let outcome = backend == .openrouter
                    ? APIResponseParser.openRouter(data)
                    : APIResponseParser.vertex(data)
                switch outcome {
                case .success(let content):
                    return content
                case .truncated(let partial):
                    // More tokens won't appear on retry; the chunker sizes requests to
                    // avoid this. The per-page OCR path keeps the partial page (losing
                    // the whole scanned doc over one dense page is worse); the
                    // structured path must fail because partial JSON is unusable.
                    if allowTruncated, !partial.isEmpty {
                        return partial + "\n\n[Transkription abgeschnitten]"
                    }
                    DebugLog.dump("hit-token-cap", partial)
                    throw ConversionError.responseTruncated
                case .providerError(let code, let message, let transient):
                    // Providers fail mid-stream behind a 200 (observed: Google 429
                    // injected into the SSE stream after ~40K chars). Retry those;
                    // deterministic refusals (SAFETY blocks) fail immediately.
                    let underlying = ConversionError.apiError(code, message)
                    if transient, attempt < maxAttempts {
                        rateLimited = rateLimited || code == 429
                        throw RetryableError(underlying: underlying)
                    }
                    throw underlying
                case .empty:
                    // Flaky providers occasionally return a well-formed body with no
                    // content; treat as transient and keep the body for forensics.
                    DebugLog.dump("empty-response", String(data: data, encoding: .utf8) ?? "<non-utf8, \(data.count) bytes>")
                    if attempt < maxAttempts {
                        throw RetryableError(underlying: ConversionError.emptyResponse)
                    }
                    throw ConversionError.emptyResponse
                }
            } catch let error as RetryableError {
                lastError = error.underlying
            } catch let error as URLError where error.code != .cancelled {
                lastError = ConversionError.network(error.localizedDescription)
            } catch {
                throw error
            }
            if attempt < maxAttempts {
                // Rate limits persist for tens of seconds; short backoffs just burn
                // attempts into the same limit window.
                let seconds = rateLimited ? UInt64(attempt) * 15 : UInt64(attempt) * 3
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
        throw lastError
    }

    private func buildRequest(model: String, system: String, userText: String, pngBase64Images: [String]) async throws -> URLRequest {
        switch backend {
        case .openrouter:
            guard !apiKey.isEmpty else { throw ConversionError.noAPIKey }
            let userContent: Any
            if pngBase64Images.isEmpty {
                userContent = userText
            } else {
                var parts: [[String: Any]] = [["type": "text", "text": userText]]
                for b64 in pngBase64Images {
                    parts.append(["type": "image_url", "image_url": ["url": "data:image/png;base64,\(b64)"]])
                }
                userContent = parts
            }
            let body: [String: Any] = [
                "model": model,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": userContent],
                ],
                "max_tokens": 65536,
            ]
            var request = URLRequest(url: Self.openRouterURL)
            request.httpMethod = "POST"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            // Non-streaming call: no bytes arrive until the full answer is generated,
            // so this idle timeout is effectively the total budget. Mistral needed 13
            // minutes for a full 17-page structured answer (measured); Gemini ~2.
            request.timeoutInterval = 1500
            return request

        case .vertex:
            guard let creds = vertexCredentials, !vertexProjectId.isEmpty, !vertexRegion.isEmpty else {
                throw ConversionError.vertexNotConfigured
            }
            let token = try await VertexTokenProvider.shared.accessToken(for: creds)
            let endpoint = "https://\(vertexRegion)-aiplatform.googleapis.com/v1/projects/\(vertexProjectId)/locations/\(vertexRegion)/publishers/google/models/\(model):generateContent"
            guard let url = URL(string: endpoint) else {
                throw ConversionError.network("invalid Vertex endpoint")
            }
            var parts: [[String: Any]] = [["text": userText]]
            for b64 in pngBase64Images {
                parts.append(["inline_data": ["mime_type": "image/png", "data": b64]])
            }
            let body: [String: Any] = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": [["role": "user", "parts": parts]],
                "generationConfig": [
                    "maxOutputTokens": 65536,
                    // Vertex enables dynamic thinking by default and the model then
                    // compresses: a 17-page doc came back as a 20K-char skeleton of a
                    // 126K-char answer. The OpenRouter route runs with reasoning off
                    // (reasoning_tokens 0) and returns the full text, so pin thinking
                    // off here too. gemini-2.5-flash accepts a budget of 0.
                    "thinkingConfig": ["thinkingBudget": 0],
                ] as [String: Any],
            ]
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            // Non-streaming call: no bytes arrive until the full answer is generated,
            // so this idle timeout is effectively the total budget. Mistral needed 13
            // minutes for a full 17-page structured answer (measured); Gemini ~2.
            request.timeoutInterval = 1500
            return request
        }
    }

    private struct RetryableError: Error {
        let underlying: Error
    }

    // MARK: - Output

    static func parseJSON(_ text: String) -> [String: Any] {
        APIResponseParser.parseJSON(text)
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
