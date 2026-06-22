# Codex Keep 0.1.27

Expands local Git repository dev-file sync.

- Adds root `fabfile_local.py` and `local_settings.py` to the existing opt-in repo dev-file sync.
- Adds root `.vscode` directory sync under the same option.
- Keeps repo-dev sync limited to trusted Macs that already have the same Git repository checkout.
