# Codex Keep 0.1.43

Adds AWS credentials to local dev file sync.

- Syncs `~/.aws/credentials` when local dev file sync is enabled.
- Copies only the credentials file, not the full `~/.aws` folder.
- Adds backup and peer-sync coverage for AWS credentials.
