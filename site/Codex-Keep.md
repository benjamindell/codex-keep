# Codex Keep 0.1.44

Falls back to peer payload archives when manifests are not hydrated.

- Reads `manifest.json` from `.codex-keep-payload.zip` when iCloud has not hydrated the visible manifest.
- Allows trusted-machine sync planning to continue instead of reporting no ready peers.
- Adds regression coverage for payload-only peer manifests.
