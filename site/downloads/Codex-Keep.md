# Codex Keep 0.1.13

Fixes peer sync failures caused by transient editor/atomic-write temp files such as `memory.md.tmp`.

- Excludes `.tmp`, Vim swap files, Emacs lock files, backup `~` files, and `.DS_Store` from future backups and file-level sync manifests.
- Ignores those transient entries if they already exist in older peer manifests.
- Stops stale transient sync tombstones from being republished.
- Keeps the Trusted Machines settings window from 0.1.11.
- Keeps trusted-machine sync from 0.1.8: file-level review, automatic non-conflicting updates, conflict copies, deletion review, tombstones, and sync safety snapshots.
