# Codex Keep 0.1.19

Restores automatic install for explicitly moved automations.

- Installs approved pending automation moves automatically before the target Mac's next backup run.
- Installs only automation IDs listed in the approved move manifest.
- Ignores stray automation folders inside a move package unless they are listed in the manifest.
- Keeps incoming move visibility and manual install in `Manage Automations...`.
- Keeps automations excluded from trusted-machine sync so scheduled jobs do not duplicate across Macs.
- Keeps `Manage Automations...` from 0.1.17 for moving selected local automations to another trusted Mac.
- Keeps stale peer manifest skipping from 0.1.14, safety snapshot hardening from 0.1.15, automation sync exclusion from 0.1.16, and explicit incoming move UI from 0.1.18.
- Keeps transient file filtering from 0.1.13.
- Keeps the Trusted Machines settings window from 0.1.11.
- Keeps trusted-machine sync from 0.1.8: file-level review, automatic non-conflicting updates, conflict copies, deletion review, tombstones, and sync safety snapshots.
