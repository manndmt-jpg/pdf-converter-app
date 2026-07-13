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
