import Foundation

struct AppSettings {
    let model: String
    let userPrompt: String
    let outputFolder: URL

    static let defaultOutputFolder = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Documents/PDF-Converted")

    static let models: [(id: String, label: String)] = [
        ("google/gemini-2.5-flash", "Gemini 2.5 Flash (fast, cheap)"),
        ("google/gemini-2.5-pro", "Gemini 2.5 Pro (complex contracts)"),
    ]

    static func current() -> AppSettings {
        let defaults = UserDefaults.standard
        let model = defaults.string(forKey: "model") ?? models[0].id
        let prompt = defaults.string(forKey: "userPrompt").flatMap { $0.isEmpty ? nil : $0 }
            ?? Prompts.defaultUserPrompt
        let folder = defaults.string(forKey: "outputFolder").map { URL(fileURLWithPath: $0) }
            ?? defaultOutputFolder
        return AppSettings(model: model, userPrompt: prompt, outputFolder: folder)
    }
}
