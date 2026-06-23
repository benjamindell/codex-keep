# Codex Keep 0.1.40

Keeps backups running when a peer manifest is temporarily unreadable.

- Skips trusted-machine manifests that exist but cannot be decoded yet.
- Prevents iCloud placeholder/corrupt peer manifests from failing the local backup.
- Adds regression coverage for malformed peer manifests.
