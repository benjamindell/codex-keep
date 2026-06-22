# Codex Keep 0.1.14

Fixes peer sync failures caused by stale peer manifests referencing files that disappeared before sync could copy them.

- Skips missing peer source files instead of failing the backup.
- Records skipped stale files in manual sync results.
- Treats local files that disappear during safety snapshot creation as missing instead of fatal.
- Keeps transient file filtering from 0.1.13.
- Keeps the Trusted Machines settings window from 0.1.11.
- Keeps trusted-machine sync from 0.1.8: file-level review, automatic non-conflicting updates, conflict copies, deletion review, tombstones, and sync safety snapshots.
