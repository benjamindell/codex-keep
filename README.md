# Codex Keep

Codex Keep is a tiny macOS menu bar app that backs up selected Codex local state to an iCloud-friendly folder.

The first version is deliberately conservative:

- It uses an allowlist instead of mirroring all of `~/.codex`.
- It backs up to `iCloud Drive/Codex Keep` when iCloud Drive is available.
- It excludes obvious secrets, large sessions, logs, caches, and live databases.
- It writes a `manifest.json` alongside the latest backup.
- It keeps one daily snapshot for each of the last seven days.
- Deploying a backup to the current Mac is intentional: Codex Keep shows a dry-run checklist and saves a safety snapshot before replacing selected local files.
- Trusted-machine sync is opt-in: choose peer Macs first, review their changes, then enable automatic sync for non-conflicting file updates when you are ready.

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

## Syncing trusted Macs

Use `Trusted Machines...` to choose which other Codex Keep machine folders this Mac should trust. Then use `Review Peer Changes...` to inspect file-level differences from those machines.

- Non-conflicting peer creates and updates are selected by default.
- Automatic trusted-machine sync applies only non-conflicting file creates and updates.
- Automatic trusted-machine sync skips peer files that are still iCloud placeholders and retries them on a later run after requesting the download.
- Automations are backed up but excluded from trusted-machine sync so scheduled jobs do not run on multiple Macs.
- Conflicts are never overwritten automatically; reviewing a conflict saves the peer copy beside the local file with a `.conflict-<machine>-<timestamp>` suffix.
- Peer deletions require review and create tombstones so the deletion can propagate deliberately.
- Every reviewed or automatic sync writes a safety snapshot under `Sync Safety` before local files are changed or deleted.

## Managing automations

Use `Manage Automations...` to move local automations to another trusted Mac. Codex Keep writes a pending move package into the target machine folder, saves an `Automation Move Safety` snapshot on the source Mac, and then removes the selected local automation folders.

The target Mac installs pending incoming moves automatically before its next backup run, using only the automation IDs listed in the approved move manifest. `Manage Automations...` also shows pending incoming moves and can install them manually. If an installed automation replaces an existing local automation, Codex Keep saves an automation move safety snapshot on the target Mac first. Automations are still excluded from trusted-machine sync, so scheduled jobs do not duplicate across Macs.

Each backup run writes phase diagnostics to `~/Library/Logs/Codex Keep/last-run.log` so long-running saves can be traced to the exact step.

If a backup run takes longer than two minutes, Codex Keep stops the menu-bar spinner, reports the last logged phase, and leaves the diagnostic log available from `Open Diagnostic Log`.

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

After updating `site/appcast.xml` and `site/downloads/Codex-Keep.zip`, deploy the static site from the linked Vercel project:

```sh
cd site
npx vercel@latest --prod --yes
```

Verify the live Sparkle feed and archive before testing from the menu bar:

```sh
curl -fsSL https://codexkeep.app/appcast.xml
curl -fsSI https://codexkeep.app/downloads/Codex-Keep.zip
```

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
