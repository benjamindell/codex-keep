# Codex Keep 0.1.50

Keeps scheduled backups moving when iCloud is slow and automatically trims generated or expired backup data.

- Requests unavailable peer and automation-move content, then retries later instead of blocking a scheduled backup.
- Extends the backup safeguard to ten minutes while keeping late-running work active until it finishes.
- Excludes common caches and makes generated visualizations opt-in.
- Retains seven days of safety history plus at least 20 snapshots, and removes stale staging or incomplete move data.
