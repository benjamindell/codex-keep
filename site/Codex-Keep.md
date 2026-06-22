# Codex Keep 0.1.20

Avoids blocking on partially downloaded automation move packages.

- Skips pending automation moves until their manifest and listed files are locally readable.
- Requests iCloud downloads for incomplete move packages without blocking the whole backup run.
- Writes backup phase diagnostics to `~/Library/Logs/Codex Keep/last-run.log`.
- Keeps automatic install for explicitly moved automations from 0.1.19.
- Keeps automations excluded from trusted-machine sync so scheduled jobs do not duplicate across Macs.
- Keeps `Manage Automations...` from 0.1.17 for moving selected local automations to another trusted Mac.
- Keeps stale peer manifest skipping from 0.1.14, safety snapshot hardening from 0.1.15, automation sync exclusion from 0.1.16, and explicit incoming move UI from 0.1.18.
- Keeps transient file filtering from 0.1.13.
- Keeps the Trusted Machines settings window from 0.1.11.
- Keeps trusted-machine sync from 0.1.8: file-level review, automatic non-conflicting updates, conflict copies, deletion review, tombstones, and sync safety snapshots.
