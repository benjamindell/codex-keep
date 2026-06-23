# Codex Keep 0.1.35

Makes first-time Codex config sync review actually adopt the peer config.

- Reviewed `Codex/config.toml` conflicts now replace the local config after a safety snapshot.
- Automatic sync still skips config conflicts until you review them.
- The review dialog now labels this case as replacing the local config instead of saving a conflict copy.
