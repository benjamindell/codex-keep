# Codex Keep 0.1.41

Syncs nested repo-local settings files.

- Finds `local_settings.py` and `fabfile_local.py` below the repo root.
- Preserves each file's relative path when backing up local repo dev files.
- Skips build, cache, Git, virtualenv, and dependency folders while scanning.
