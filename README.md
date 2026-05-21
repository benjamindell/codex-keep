# Codex Keep

Codex Keep is a tiny macOS menu bar app that backs up selected Codex local state to an iCloud-friendly folder.

The first version is deliberately conservative:

- It uses an allowlist instead of mirroring all of `~/.codex`.
- It backs up to `iCloud Drive/Codex Keep` when iCloud Drive is available.
- It excludes obvious secrets, large sessions, logs, caches, and live databases.
- It writes a `manifest.json` alongside the latest backup.
- It keeps one daily snapshot for each of the last seven days.
- Restore is intentionally manual for now.

## Default backup set

- `~/.codex/automations` to `Codex/automations`
- `~/.codex/AGENTS.md` to `Codex/AGENTS.md`
- `~/.codex/config.toml` to `Codex/config.toml`
- `~/.codex/rules` to `Codex/rules`
- `~/.codex/skills` to `Codex/skills`, excluding bundled/system skills
- `~/.agents/skills` to `Agents/skills`

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
