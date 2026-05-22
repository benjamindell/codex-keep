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
