# Codex Keep 0.1.51

Prevents incomplete automation moves and makes their safety snapshots usable for recovery.

- Checks that incoming automation files match the move manifest before installing them.
- Keeps incomplete moves pending until their files or archive are available.
- Lets you restore the automations in an Automation Move Safety snapshot through Deploy Backup to This Mac.
