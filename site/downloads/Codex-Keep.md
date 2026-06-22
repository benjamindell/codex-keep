# Codex Keep 0.1.25

Gives iCloud-backed peer archives enough time to hydrate and confirms the running build in diagnostics.

- Retries extraction of the peer payload archive instead of relying only on iCloud readiness metadata.
- Extends the bounded backup watchdog to allow a real archive download to finish.
- Logs the Codex Keep version/build at the start of each backup run.
