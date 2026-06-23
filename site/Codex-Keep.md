# Codex Keep 0.1.39

Cleans up peer review for Codex memory files.

- Hides `.git` internals from backups and peer-review sync lists.
- Filters older peer manifests that still contain memory Git metadata.
- Ignores peer deletion tombstones for `Codex/config.toml`.
