# Setup Guide (step by step)

Five minutes from zero to converting PDFs. No technical knowledge needed for the standard setup.

## 1. Install the app

1. Download the newest `PDFConverter-x.y.zip` from the [releases page](../../releases/latest)
2. Double-click the zip to unpack it
3. Drag `PDFConverter.app` into your `Applications` folder
4. Open it. No security warnings should appear (the app is checked by Apple)

The app needs an AI provider to do the actual conversion. Pick ONE of the two options below. If unsure, take Option A.

## 2. Option A: OpenRouter (standard, 5 minutes)

OpenRouter is a pay-as-you-go AI service. A typical document costs a fraction of a cent, so 5 USD of credit lasts a very long time.

1. Go to [openrouter.ai](https://openrouter.ai) and sign up (Google login works)
2. Click your profile picture (top right), then **Credits**, and buy credits (5 USD is plenty to start)
3. Click your profile picture again, then **Keys**, then **Create Key**. Give it any name, e.g. "pdf-converter"
4. Copy the key that appears (it starts with `sk-or-`). Copy it right away, it is only shown once
5. Open PDF Converter, press **Cmd + ,** (or click the gear icon) to open Settings
6. Make sure **Provider** is set to **OpenRouter**
7. Paste your key into the **API Key** field
8. Click **Test Key**. You should see "OK, key is valid"

Done. Close Settings and drop a PDF onto the app window.

## 3. Option B: Vertex AI EU (for confidential documents)

With this option the document content is processed by Google in the EU (Belgium) instead of being routed through a US service. Use this for anything sensitive. It requires access to our Google Cloud project, so there is a one-time setup with a terminal command. It looks scarier than it is.

1. Ask Dimitri to add your Google account to the Google Cloud project
2. Install the Google Cloud tools. Open the Terminal app and paste:
   ```
   brew install google-cloud-sdk
   ```
   (If `brew` is not installed, get it first from [brew.sh](https://brew.sh))
3. Log in with your Google account. Paste this in Terminal:
   ```
   gcloud auth application-default login
   ```
   A browser window opens; log in and allow access
4. Show your credentials file. Paste this in Terminal:
   ```
   cat ~/.config/gcloud/application_default_credentials.json
   ```
   Select and copy the whole output (a block of text in curly braces)
5. Open PDF Converter Settings (**Cmd + ,**)
6. Set **Provider** to **Vertex AI (EU)**
7. Enter the **GCP Project ID** (ask Dimitri, or it was in the invite you received)
8. Leave **Region** as `europe-west1`
9. Paste the copied text block into the **Credentials JSON** field
10. Click **Test Connection**. You should see "OK"

## 4. Using the app

- Drag one or more PDFs onto the app window (or onto its Dock icon)
- Watch the progress. Scanned documents take longer, roughly 5 to 10 seconds per page
- Converted `.md` files land in `Documents/PDF-Converted` in your home folder ("Output Folder" button in the app opens it)
- Open a `.md` file with any text editor, or paste its content straight into Claude or another AI chat

## 5. If something does not work

| Problem | Fix |
|---|---|
| "No API key set" | Do step 2 (Option A) or step 3 (Option B) |
| "Invalid key" on Test Key | The key was copied incompletely, create a new one at openrouter.ai and paste again |
| "Access denied" on Test Connection | Your Google account is not in the project yet, ask Dimitri |
| "Google token refresh failed" | Run `gcloud auth application-default login` again and re-paste the JSON (step 3.3 to 3.9) |
| A file shows red with a network error | Check your internet, then click Retry on that file |
| Conversion is stuck | Click the x on the file to cancel and drop it again |

Anything else: message Dimitri.

## Privacy reminder

Whatever PDF you drop is sent to an AI service for processing (see the [README privacy note](README.md#privacy-note)). With OpenRouter, routing goes through a US provider. With Vertex AI (EU) it stays with Google in the EU. For confidential customer documents, use Option B or ask before converting.
