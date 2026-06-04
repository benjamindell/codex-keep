# Codex Keep

Codex Keep is a tiny macOS menu bar app that backs up selected Codex local state to an iCloud-friendly folder.

The first version is deliberately conservative:

- It uses an allowlist instead of mirroring all of `~/.codex`.
- It backs up to `iCloud Drive/Codex Keep` when iCloud Drive is available.
- It excludes obvious secrets, large sessions, logs, caches, and live databases.
- It writes a `manifest.json` alongside the latest backup.
- It keeps one daily snapshot for each of the last seven days.
- Deploying a backup to the current Mac is intentional: Codex Keep shows a dry-run checklist and saves a safety snapshot before replacing selected local files.

## Default backup set

- `~/.codex/automations` to `Codex/automations`
- `~/.codex/AGENTS.md` to `Codex/AGENTS.md`
- `~/.codex/config.toml` to `Codex/config.toml`
- `~/.codex/rules` to `Codex/rules`
- `~/.codex/skills` to `Codex/skills`, excluding bundled/system skills
- Markdown-backed top-level `~/.codex` folders to `Codex/<folder>`, excluding known cache, session, log, plugin, database, and worktree folders
- `~/.agents/skills` to `Agents/skills`

## Deploying to another Mac

Use `Deploy Backup to This Mac...` from the menu bar app to seed or update a Mac from a Codex Keep backup. You can choose a machine folder, a `latest` folder, or a dated snapshot.

Codex Keep reviews the backup before writing anything:

- Automations are shown individually so mature daily jobs can move to an always-on Mac without pulling every automation away from your main machine.
- Shared items like `AGENTS.md`, config, rules, and skills are shown as broader items.
- New and changed items are selected by default; unchanged items are left unchecked.
- A restore safety snapshot of the selected local items is written under `Restore Safety` before anything is replaced.

## Development

```sh
swift test
swift run CodexKeep
```

Build an app bundle:

```sh
chmod +x Packaging/make_app.sh
Packaging/make_app.sh
```

The built app bundle is written to `.build/release/Codex Keep.app`.

## Updates

Codex Keep uses Sparkle for update checks.

- Feed: `https://codexkeep.app/appcast.xml`
- Current download: `https://codexkeep.app/downloads/Codex-Keep.zip`
- The app has a `Check for Updates...` menu item.
- Automatic checks are enabled through `SUEnableAutomaticChecks`.

Release archives are signed with Sparkle's EdDSA key. The public key is embedded in `Packaging/Info.plist`; the private key is stored in the local macOS Keychain.

## Backup layout

```text
Codex Keep/
  <machine-name>/
    latest/
      Agents/
      Codex/
      manifest.json
    Snapshots/
      2026-05-21/
      2026-05-20/
```

`latest` is refreshed in place. `Snapshots` keeps the seven newest daily backups.
