import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("backend") private var backendRaw = Backend.openrouter.rawValue
    @AppStorage("model") private var model = AppSettings.models[0].id
    @AppStorage("userPrompt") private var userPrompt = Prompts.defaultUserPrompt
    @AppStorage("outputFolder") private var outputFolderPath = AppSettings.defaultOutputFolder.path
    @AppStorage("vertexProjectId") private var vertexProjectId = ""
    @AppStorage("vertexRegion") private var vertexRegion = "europe-west1"
    @AppStorage("vertexCredentialsJSON") private var vertexCredentialsJSON = ""

    @State private var apiKey: String = Keychain.readAPIKey() ?? ""
    @State private var keyTestResult: String?
    @State private var isTestingKey = false

    private var backend: Backend { Backend(rawValue: backendRaw) ?? .openrouter }

    var body: some View {
        Form {
            Section("Backend") {
                Picker("Provider", selection: $backendRaw) {
                    Text(Backend.openrouter.label).tag(Backend.openrouter.rawValue)
                    Text(Backend.vertex.label).tag(Backend.vertex.rawValue)
                }
                .pickerStyle(.segmented)
                .onChange(of: backendRaw) { _, _ in keyTestResult = nil }
                if backend == .vertex {
                    Text("Document content is processed by Google Vertex AI in the EU region.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if backend == .openrouter {
                Section("OpenRouter") {
                    SecureField("API Key", text: $apiKey)
                        .onChange(of: apiKey) { _, newValue in
                            Keychain.saveAPIKey(newValue.trimmingCharacters(in: .whitespacesAndNewlines))
                            keyTestResult = nil
                        }
                    HStack {
                        Button(isTestingKey ? "Testing…" : "Test Key") { testKey() }
                            .disabled(apiKey.isEmpty || isTestingKey)
                        testResultLabel
                    }
                    Picker("Model", selection: $model) {
                        ForEach(AppSettings.models, id: \.id) { m in
                            Text(m.label).tag(m.id)
                        }
                    }
                }
            } else {
                Section("Vertex AI") {
                    TextField("GCP Project ID", text: $vertexProjectId)
                    TextField("Region", text: $vertexRegion)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Credentials JSON (from: gcloud auth application-default login)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $vertexCredentialsJSON)
                            .font(.system(.caption, design: .monospaced))
                            .frame(height: 70)
                            .onChange(of: vertexCredentialsJSON) { _, _ in keyTestResult = nil }
                    }
                    HStack {
                        Button(isTestingKey ? "Testing…" : "Test Connection") { testVertex() }
                            .disabled(vertexProjectId.isEmpty || vertexCredentialsJSON.isEmpty || isTestingKey)
                        testResultLabel
                    }
                    Text("Model: \(AppSettings.vertexModel) (only model deployed in \(vertexRegion))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var testResultLabel: some View {
        if let result = keyTestResult {
            Text(result)
                .font(.caption)
                .foregroundStyle(result.hasPrefix("OK") ? .green : .red)
        }
    }

    private func testVertex() {
        isTestingKey = true
        keyTestResult = nil
        let project = vertexProjectId.trimmingCharacters(in: .whitespaces)
        let region = vertexRegion.trimmingCharacters(in: .whitespaces)
        let credsJSON = vertexCredentialsJSON
        Task {
            defer { isTestingKey = false }
            guard let creds = VertexCredentials.parse(credsJSON) else {
                keyTestResult = "Invalid credentials JSON (needs client_id, client_secret, refresh_token)"
                return
            }
            do {
                let token = try await VertexTokenProvider.shared.accessToken(for: creds)
                var request = URLRequest(url: URL(string:
                    "https://\(region)-aiplatform.googleapis.com/v1/projects/\(project)/locations/\(region)/publishers/google/models/\(AppSettings.vertexModel):generateContent")!)
                request.httpMethod = "POST"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: [
                    "contents": [["role": "user", "parts": [["text": "Say hi"]]]],
                    "generationConfig": ["maxOutputTokens": 10],
                ])
                request.timeoutInterval = 15
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch code {
                case 200: keyTestResult = "OK — \(AppSettings.vertexModel) reachable in \(region)"
                case 403: keyTestResult = "Access denied — check project IAM / Vertex AI API enabled"
                case 404: keyTestResult = "Project or region not found"
                default: keyTestResult = "HTTP \(code): \(String(data: data, encoding: .utf8)?.prefix(80) ?? "")"
                }
            } catch {
                keyTestResult = "Failed: \(error.localizedDescription)"
            }
        }
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
