# Codex Keep 0.1.23

Shows exactly when trusted-machine sync skipped peer files that are still downloading from iCloud.

- Logs skipped peer file paths in `~/Library/Logs/Codex Keep/last-run.log`.
- Shows skipped peer file counts in the menu bar status instead of looking like a clean no-op.
- Adds regression coverage for syncing a new file inside an existing skill folder.
- Keeps iCloud placeholder skipping from 0.1.22 so automatic sync does not hang while waiting for iCloud.
- Keeps the two-minute watchdog and diagnostic log from 0.1.21.
- Keeps non-blocking iCloud automation move handling from 0.1.20.
- Keeps automatic install for explicitly moved automations from 0.1.19.
- Keeps automations excluded from trusted-machine sync so scheduled jobs do not duplicate across Macs.
- Keeps `Manage Automations...` from 0.1.17 for moving selected local automations to another trusted Mac.
- Keeps stale peer manifest skipping from 0.1.14, safety snapshot hardening from 0.1.15, automation sync exclusion from 0.1.16, and explicit incoming move UI from 0.1.18.
- Keeps transient file filtering from 0.1.13.
- Keeps the Trusted Machines settings window from 0.1.11.
- Keeps trusted-machine sync from 0.1.8: file-level review, automatic non-conflicting updates, conflict copies, deletion review, tombstones, and sync safety snapshots.
