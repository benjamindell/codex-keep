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
- Optional local repo dev files to `Git Repos/<repo identity>`, currently root `.env` and `.env.*` files, `fabfile_local.py`, `local_settings.py`, and `.vscode`
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
- Each backup publishes `.codex-keep-payload.zip` next to `manifest.json` so peer sync can recover files even when iCloud has hydrated the manifest before the individual file tree.
- Automatic trusted-machine sync skips peer files that are still iCloud placeholders, logs their backup paths, shows the skipped count in the menu, and retries them on a later run after requesting the download.
- Automations are backed up but excluded from trusted-machine sync so scheduled jobs do not run on multiple Macs.
- Codex app/config sync is limited to `~/.codex/config.toml`; Codex Keep does not sync the Electron app profile, auth files, databases, sessions, logs, or caches.
- `Sync Local Repo Dev Files` is opt-in. When enabled, Codex Keep backs up supported local-only dev files from discovered Git repositories and syncs them only to trusted Macs that already have the same repository checkout.
- Conflicts are never overwritten automatically; reviewing a conflict saves the peer copy beside the local file with a `.conflict-<machine>-<timestamp>` suffix.
- Peer deletions require review and create tombstones so the deletion can propagate deliberately.
- Every reviewed or automatic sync writes a safety snapshot under `Sync Safety` before local files are changed or deleted.

## Managing automations

Use `Manage Automations...` to move local automations to another trusted Mac. Codex Keep writes a pending move package into the target machine folder, saves an `Automation Move Safety` snapshot on the source Mac, and then removes the selected local automation folders.

The target Mac installs pending incoming moves automatically before its next backup run, using only the automation IDs listed in the approved move manifest. `Manage Automations...` also shows pending incoming moves and can install them manually. If an installed automation replaces an existing local automation, Codex Keep saves an automation move safety snapshot on the target Mac first. Automations are still excluded from trusted-machine sync, so scheduled jobs do not duplicate across Macs.

Each backup run writes phase diagnostics to `~/Library/Logs/Codex Keep/last-run.log` so long-running saves can be traced to the exact step.

If a backup run takes longer than two minutes, Codex Keep stops the menu-bar spinner, reports the last logged phase, and leaves the diagnostic log available from `Open Diagnostic Log`.

## Secondary Machine Mode

Use `Secondary Machine Mode` on always-on Macs that should stay ready for remote Codex work.

- Every 30 minutes, Codex Keep pulls clean Git repositories in `~/Repositories`.
- Once per day at 5:00 a.m. local time, Codex Keep checks `/Applications/Codex.app` for a Sparkle update and installs it silently only if Codex does not appear to be running local work.
- Codex app updates are skipped when Codex Keep is backing up or pulling repositories, or when Codex has active work processes such as `codex app-server --listen stdio://` or `kernel.js`.
- Codex app update diagnostics are written to `~/Library/Logs/Codex Keep/codex-app-updates.log`.

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

Sparkle release notes should be specific to the version being shipped. Keep `site/Codex-Keep.md` and `site/downloads/Codex-Keep.md` short: one practical summary sentence and two to four bullets about the current change. Avoid repeating old "keeps previous behavior" bullets unless that preserved behavior is the point of the release.

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
