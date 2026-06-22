# Codex Keep 0.1.32

Prevents Secondary Machine Mode repository pulls from getting stuck silently.

- Adds per-repository progress lines to the repository pull log.
- Times out hung Git commands and marks that repository as skipped.
- Forces Git credential prompts to stay non-interactive during background pulls.
