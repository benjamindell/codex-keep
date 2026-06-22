# Codex Keep 0.1.17

Adds Manage Automations for moving scheduled jobs between trusted Macs.

- Adds `Manage Automations...` to move selected local automations to another trusted Mac.
- Writes a pending move package for the target Mac and deletes the local automation only after a safety snapshot exists.
- Installs pending automation moves on the target Mac before its next backup run.
- Keeps automations excluded from trusted-machine sync so scheduled jobs do not duplicate across Macs.
- Keeps stale peer manifest skipping from 0.1.14, safety snapshot hardening from 0.1.15, and automation sync exclusion from 0.1.16.
- Keeps transient file filtering from 0.1.13.
- Keeps the Trusted Machines settings window from 0.1.11.
- Keeps trusted-machine sync from 0.1.8: file-level review, automatic non-conflicting updates, conflict copies, deletion review, tombstones, and sync safety snapshots.
