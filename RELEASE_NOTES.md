# Version 1.8

Reliability release: dense and large documents now convert dependably.

- Fixed dense documents failing with cut-off answers or raw JSON output
- Automatic retries when the AI provider is overloaded, with patient backoff
- Very large documents are split into parts automatically and merged seamlessly
- Vertex AI results no longer come back as short skeleton summaries
- Automatic fallback to Mistral when Gemini capacity is exhausted
- Incomplete answers are rejected and retried instead of saved as done
- Scanned PDFs: one difficult page no longer fails the whole document
- Live elapsed timer while converting, and one-click remove for history entries
- Very long documents no longer freeze the preview
