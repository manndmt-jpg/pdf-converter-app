import Foundation

// Interprets a 200-OK response body from either backend. OpenRouter can embed an
// upstream provider failure inside choices[0] (finish_reason "error" plus an error
// object) AFTER streaming partial content, so reading message.content alone
// mistakes a failed call for a success and hands truncated JSON downstream.
// Foundation-only on purpose: scratch harnesses compile this file standalone.
enum APIResponseParser {
    enum Outcome: Equatable {
        case success(String)
        // transient = worth retrying (rate limit / server hiccup); false for
        // deterministic refusals like Gemini SAFETY blocks.
        case providerError(code: Int, message: String, transient: Bool)
        case truncated(partial: String)                 // generation hit max_tokens
        case empty
    }

    static func openRouter(_ data: Data) -> Outcome {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let choice = choices.first
        else { return .empty }
        let content = ((choice["message"] as? [String: Any])?["content"] as? String) ?? ""
        if let error = choice["error"] as? [String: Any] {
            // The code arrives as Int normally, but tolerate a string-typed code so a
            // permanent 4xx does not default to 0 and get retried as transient.
            let code = (error["code"] as? Int) ?? Int((error["code"] as? String) ?? "") ?? 0
            let message = (error["message"] as? String) ?? "provider error"
            return .providerError(code: code, message: message, transient: code == 0 || code == 429 || code >= 500)
        }
        let finish = choice["finish_reason"] as? String
        if finish == "error" { return .providerError(code: 0, message: "provider error", transient: true) }
        if finish == "length" { return .truncated(partial: content) }
        return content.isEmpty ? .empty : .success(content)
    }

    // Parses the model's structured answer, tolerating the usual LLM sins: markdown
    // fences, prose around the JSON, and raw control characters inside string values
    // (Gemini intermittently emits literal newlines instead of \n; strict JSON parsers
    // reject the whole answer over one such character).
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
        if let obj = attempt(escapeControlCharsInStrings(clean)) { return obj }
        // Last resort: model wrapped the JSON in prose or stray fences — take outermost
        // braces. Slice BEFORE repairing: an odd quote in surrounding prose would flip
        // the repairer's in-string tracking and corrupt structural whitespace.
        if let start = clean.firstIndex(of: "{"), let end = clean.lastIndex(of: "}"), start < end {
            let slice = String(clean[start...end])
            if let obj = attempt(slice) { return obj }
            if let obj = attempt(escapeControlCharsInStrings(slice)) { return obj }
        }
        return ["raw_response": text]
    }

    // Escapes raw control characters that occur INSIDE JSON string literals, leaving
    // structural whitespace between tokens untouched. Tracks escape state so \" and
    // \\ sequences do not confuse the in-string detection.
    static func escapeControlCharsInStrings(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(s.unicodeScalars.count)
        var inString = false
        var escaped = false
        for scalar in s.unicodeScalars {
            if inString {
                if escaped {
                    escaped = false
                    out.append(scalar)
                    continue
                }
                switch scalar {
                case "\\":
                    escaped = true
                    out.append(scalar)
                case "\"":
                    inString = false
                    out.append(scalar)
                case "\n":
                    out.append(contentsOf: "\\n".unicodeScalars)
                case "\r":
                    out.append(contentsOf: "\\r".unicodeScalars)
                case "\t":
                    out.append(contentsOf: "\\t".unicodeScalars)
                default:
                    if scalar.value < 0x20 {
                        out.append(contentsOf: String(format: "\\u%04x", scalar.value).unicodeScalars)
                    } else {
                        out.append(scalar)
                    }
                }
            } else {
                if scalar == "\"" { inString = true }
                out.append(scalar)
            }
        }
        return String(out)
    }

    static func vertex(_ data: Data) -> Outcome {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let candidates = obj["candidates"] as? [[String: Any]],
              let candidate = candidates.first
        else { return .empty }
        let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        if let finish = candidate["finishReason"] as? String {
            if finish == "MAX_TOKENS" { return .truncated(partial: text) }
            // SAFETY / RECITATION / BLOCKLIST etc. are deterministic; retrying wastes time.
            if finish != "STOP" { return .providerError(code: 0, message: "finishReason \(finish)", transient: false) }
        }
        return text.isEmpty ? .empty : .success(text)
    }
}
