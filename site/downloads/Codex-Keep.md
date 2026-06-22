# Codex Keep 0.1.16

Keeps Codex automations out of trusted-machine sync.

- Automations are still backed up for recovery and future move tooling.
- Automations are excluded from peer sync so scheduled jobs do not run on multiple Macs.
- Adds regression coverage to keep automation files out of peer sync plans.
- Keeps stale peer manifest skipping from 0.1.14 and safety snapshot hardening from 0.1.15.
- Keeps transient file filtering from 0.1.13.
- Keeps the Trusted Machines settings window from 0.1.11.
- Keeps trusted-machine sync from 0.1.8: file-level review, automatic non-conflicting updates, conflict copies, deletion review, tombstones, and sync safety snapshots.
