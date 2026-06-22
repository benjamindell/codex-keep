# Codex Keep 0.1.10

Fixes trusted-machine discovery for iCloud Drive folders that are visible in Finder before every `latest` manifest has hydrated locally.

- Shows visible peer machine backup folders instead of hiding them while iCloud is still downloading metadata.
- Asks iCloud Drive to download peer `latest` and manifest data before reading it.
- Keeps trusted-machine sync from 0.1.8: file-level review, automatic non-conflicting updates, conflict copies, deletion review, tombstones, and sync safety snapshots.
