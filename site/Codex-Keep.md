# Codex Keep 0.1.34

Adds daily Codex app update supervision for secondary machines.

- Checks `/Applications/Codex.app` at 5:00 a.m. local time when Secondary Machine Mode is enabled.
- Skips the update when Codex Keep is backing up, pulling repositories, or Codex appears to be running active work.
- Adds menu actions to run the Codex app update check manually and open its log.
