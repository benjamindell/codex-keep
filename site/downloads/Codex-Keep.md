# Codex Keep 0.1.7

Adds `Deploy Backup to This Mac...`, a selective restore flow for seeding another Mac from a Codex Keep backup.

- Review a backup before restoring anything.
- Restore individual automations, so mature jobs can move to an always-on runner without pulling every automation away from your main Mac.
- Restore shared Codex items such as `AGENTS.md`, config, rules, and skills.
- Save a restore safety snapshot before replacing selected local files.
- Exclude nested `node_modules` folders from Codex skill backups to avoid copying installed dependencies.
