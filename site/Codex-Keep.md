# Codex Keep 0.1.29

Fixes backups for Codex skills that are symlinked to another local skills folder.

- Copies symlinked skill directories as real folder content in the backup.
- Includes those skill files in the manifest and payload archive so peer sync can install them.
- Adds regression coverage for symlinked Codex skills.
