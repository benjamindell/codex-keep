# Codex Keep 0.1.36

Prevents missing peer manifests from failing a backup.

- Skips trusted-machine peers whose `latest/manifest.json` is not ready yet.
- Keeps the backup running when iCloud has not hydrated a peer manifest.
- Logs when no trusted peer manifests were ready for sync.
