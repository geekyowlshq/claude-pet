---
name: remove
description: Remove a saved account from Claude Pet.
argument-hint: "<name>"
disable-model-invocation: true
allowed-tools: Bash(claude-pet:*)
---

Confirm with the user before deleting, then run `claude-pet remove $ARGUMENTS`. If it's the account in use, Claude Pet switches to another saved account first (restart running claude sessions afterwards). If it's the only account, it's just forgotten and the apps stay logged in.
