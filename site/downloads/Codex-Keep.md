# Codex Keep 0.1.12

Fixes peer sync failures caused by Finder `.DS_Store` metadata files.

- Excludes `.DS_Store` from future backups and file-level sync manifests.
- Ignores `.DS_Store` entries that may already exist in older peer manifests.
- Stops stale `.DS_Store` sync tombstones from being republished.
- Keeps the Trusted Machines settings window from 0.1.11.
- Keeps trusted-machine sync from 0.1.8: file-level review, automatic non-conflicting updates, conflict copies, deletion review, tombstones, and sync safety snapshots.
