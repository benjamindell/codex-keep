# Codex Keep 0.1.24

Makes trusted-machine sync resilient when iCloud hydrates `manifest.json` before the peer file tree.

- Adds `.codex-keep-payload.zip` beside each backup manifest.
- Falls back to the payload archive when a peer manifest lists a file but iCloud has not materialized that individual file path locally.
- Adds regression coverage for manifest-present/tree-missing peer files.
- Keeps skipped peer path logging from 0.1.23.
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
