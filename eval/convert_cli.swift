import Foundation

// Headless conversion runner: converts a PDF through the exact in-app pipeline
// (structured call, binding pass, audits, fallbacks) without launching the GUI,
// so prompt/pipeline changes can be verified end to end from a terminal.
// OpenRouter only; key from $OPENROUTER_API_KEY or the app's Keychain item.
//
//   swiftc -parse-as-library -O -o /tmp/convert_cli eval/convert_cli.swift \
//       Sources/{Converter,APIResponseParser,DocumentChunker,ClauseAudit,ClauseBinding,MarkdownRenderer,DebugLog,Prompts,Keychain,VertexAuth,AppSettings,PageFurniture,OrphanItemAudit}.swift
//   /tmp/convert_cli <file.pdf> <output-dir>
//
// Prints the output path on stdout; progress goes to stderr; a non-fatal audit
// warning is printed as "WARNING: …".

@main
struct ConvertCLI {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            FileHandle.standardError.write(Data("usage: convert_cli <file.pdf> <output-dir>\n".utf8))
            exit(2)
        }
        let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"] ?? Keychain.readAPIKey() ?? ""
        guard !key.isEmpty else {
            FileHandle.standardError.write(Data("no OpenRouter key: set OPENROUTER_API_KEY or store it via the app\n".utf8))
            exit(2)
        }
        let converter = Converter(
            backend: .openrouter,
            apiKey: key,
            model: AppSettings.models[0].id,
            userPrompt: Prompts.defaultUserPrompt,
            outputFolder: URL(fileURLWithPath: args[2]),
            vertexProjectId: "",
            vertexRegion: "",
            vertexCredentials: nil)
        do {
            let result = try await converter.convert(url: URL(fileURLWithPath: args[1])) { message, _ in
                FileHandle.standardError.write(Data("\(message)\n".utf8))
            }
            print(result.outputURL.path)
            if let warning = result.warning { print("WARNING: \(warning)") }
        } catch {
            FileHandle.standardError.write(Data("FAILED: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
