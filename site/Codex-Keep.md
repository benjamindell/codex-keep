# Codex Keep 0.1.38

Hardens config sync verification and backup publishing.

- Verifies replaced peer files by hash before reporting sync success.
- Publishes backups through a temporary folder so a failed copy does not expose an incomplete `latest`.
- Skips symlinked local repo dev folders such as `.vscode` during backup.
