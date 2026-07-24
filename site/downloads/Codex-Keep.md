# Codex Keep 0.1.47

Prevents Codex runtime state from bloating backups and causing timeouts on secondary Macs.

- Excludes `~/.codex/state` even when it contains Markdown files.
- Keeps user-authored top-level Markdown folders eligible for backup and trusted-machine sync.
