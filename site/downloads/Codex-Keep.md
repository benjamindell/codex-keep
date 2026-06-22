# Codex Keep 0.1.21

Stops endless saving indicators and exposes diagnostics.

- Adds a two-minute watchdog so the menu bar does not stay in Saving forever.
- Reports the last logged backup phase when a run times out.
- Adds `Open Diagnostic Log` to the menu.
- Keeps non-blocking iCloud automation move handling from 0.1.20.
- Keeps automatic install for explicitly moved automations from 0.1.19.
- Keeps automations excluded from trusted-machine sync so scheduled jobs do not duplicate across Macs.
- Keeps `Manage Automations...` from 0.1.17 for moving selected local automations to another trusted Mac.
- Keeps stale peer manifest skipping from 0.1.14, safety snapshot hardening from 0.1.15, automation sync exclusion from 0.1.16, and explicit incoming move UI from 0.1.18.
- Keeps transient file filtering from 0.1.13.
- Keeps the Trusted Machines settings window from 0.1.11.
- Keeps trusted-machine sync from 0.1.8: file-level review, automatic non-conflicting updates, conflict copies, deletion review, tombstones, and sync safety snapshots.
