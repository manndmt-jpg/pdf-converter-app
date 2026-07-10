import Foundation

enum Backend: String {
    case openrouter
    case vertex

    var label: String {
        switch self {
        case .openrouter: return "OpenRouter"
        case .vertex: return "Vertex AI (EU)"
        }
    }
}

struct AppSettings {
    let backend: Backend
    let model: String
    let userPrompt: String
    let outputFolder: URL
    let vertexProjectId: String
    let vertexRegion: String
    let vertexCredentials: VertexCredentials?

    // Only gemini-2.5-flash is deployed in europe-west1
    static let vertexModel = "gemini-2.5-flash"

    var hasVertexConfig: Bool {
        !vertexProjectId.isEmpty && !vertexRegion.isEmpty && vertexCredentials != nil
    }

    static let defaultOutputFolder = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/PDF-Converted")

    static let models: [(id: String, label: String)] = [
        ("google/gemini-2.5-flash", "Gemini 2.5 Flash (fast, cheap)"),
        ("google/gemini-2.5-pro", "Gemini 2.5 Pro (complex contracts)"),
    ]

    static func current() -> AppSettings {
        let defaults = UserDefaults.standard
        let backend = defaults.string(forKey: "backend").flatMap(Backend.init(rawValue:)) ?? .openrouter
        let model = defaults.string(forKey: "model") ?? models[0].id
        let prompt = defaults.string(forKey: "userPrompt").flatMap { $0.isEmpty ? nil : $0 }
            ?? Prompts.defaultUserPrompt
        let folder = defaults.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0) }
            ?? defaultOutputFolder
        return AppSettings(
            backend: backend,
            model: backend == .vertex ? vertexModel : model,
            userPrompt: prompt,
            outputFolder: folder,
            vertexProjectId: defaults.string(forKey: "vertexProjectId") ?? "",
            vertexRegion: defaults.string(forKey: "vertexRegion") ?? "europe-west1",
            vertexCredentials: (defaults.string(forKey: "vertexCredentialsJSON") ?? "")
                .isEmpty ? nil : VertexCredentials.parse(defaults.string(forKey: "vertexCredentialsJSON") ?? "")
        )
    }
}
