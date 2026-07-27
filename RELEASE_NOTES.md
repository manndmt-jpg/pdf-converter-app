# Version 1.13

- Vertex AI (EU) can now be set up with a service account key file, not just a
  personal Google login. Paste the key's contents into the same Credentials JSON
  field in Settings and the app handles the rest, so a new user no longer has to
  install the Google Cloud tools or run anything in Terminal.
- Test Connection now names the account it connected as, so it is obvious whether
  the app is using a shared key or your own login.
- Clearer messages when Vertex credentials are wrong or rejected: the old text
  always told you to re-run a gcloud command, which was no help if you had pasted
  a key file.
