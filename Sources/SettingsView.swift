import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("model") private var model = AppSettings.models[0].id
    @AppStorage("userPrompt") private var userPrompt = Prompts.defaultUserPrompt
    @AppStorage("outputFolder") private var outputFolderPath = AppSettings.defaultOutputFolder.path

    @State private var apiKey: String = Keychain.readAPIKey() ?? ""
    @State private var keyTestResult: String?
    @State private var isTestingKey = false

    var body: some View {
        Form {
            Section("OpenRouter") {
                SecureField("API Key", text: $apiKey)
                    .onChange(of: apiKey) { _, newValue in
                        Keychain.saveAPIKey(newValue.trimmingCharacters(in: .whitespacesAndNewlines))
                        keyTestResult = nil
                    }
                HStack {
                    Button(isTestingKey ? "Testing…" : "Test Key") { testKey() }
                        .disabled(apiKey.isEmpty || isTestingKey)
                    if let result = keyTestResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(result.hasPrefix("OK") ? .green : .red)
                    }
                }
                Picker("Model", selection: $model) {
                    ForEach(AppSettings.models, id: \.id) { m in
                        Text(m.label).tag(m.id)
                    }
                }
            }

            Section("Output") {
                HStack {
                    Text(outputFolderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Choose…") { chooseFolder() }
                }
            }

            Section("Prompt") {
                TextEditor(text: $userPrompt)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 80)
                Button("Reset to Default") {
                    userPrompt = Prompts.defaultUserPrompt
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: outputFolderPath)
        if panel.runModal() == .OK, let url = panel.url {
            outputFolderPath = url.path
        }
    }

    private func testKey() {
        isTestingKey = true
        keyTestResult = nil
        let key = apiKey
        Task {
            defer { isTestingKey = false }
            var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/key")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.timeoutInterval = 15
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                keyTestResult = code == 200 ? "OK — key is valid" : "Invalid key (HTTP \(code))"
            } catch {
                keyTestResult = "Network error: \(error.localizedDescription)"
            }
        }
    }
}
