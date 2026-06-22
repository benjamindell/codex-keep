# Codex Keep 0.1.15

Hardens peer sync safety snapshots against duplicate target paths and file/directory copy collisions.

- Snapshots each local sync target at most once.
- Replaces existing safety-snapshot destinations instead of failing if they already exist.
- Keeps stale peer manifest skipping from 0.1.14.
- Keeps transient file filtering from 0.1.13.
- Keeps the Trusted Machines settings window from 0.1.11.
- Keeps trusted-machine sync from 0.1.8: file-level review, automatic non-conflicting updates, conflict copies, deletion review, tombstones, and sync safety snapshots.
