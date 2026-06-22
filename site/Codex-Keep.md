# Codex Keep 0.1.26

Adds opt-in sync for local Git repository dev files.

- Adds a `Sync Local Repo Dev Files` menu toggle.
- Backs up root `.env` and `.env.*` files for discovered Git repositories, excluding example/template files.
- Syncs those files only when the receiving Mac already has the same Git repository checkout.
