# Codex Keep 0.1.30

Stops backing up symlinked Codex skill directories.

- Reverses the 0.1.29 symlink-following behavior.
- Keeps linked skills out of the backup when they point at local plugin or agent-managed folders.
- Adds regression coverage for skipping symlinked Codex skills.
