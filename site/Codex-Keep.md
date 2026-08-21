# Codex Keep 0.1.49

Makes trusted-Mac skill sync resilient when iCloud exposes a new backup only partially.

- Publishes immutable sync generations backed by deduplicated, content-addressed files.
- Uses the previous complete generation while a newer iCloud generation is unavailable.
- Detects metadata-only iCloud placeholders, requests their download, and records the waiting state in the diagnostic log.
