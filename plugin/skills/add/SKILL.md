---
name: add
description: Add another Claude account to Claude Pet.
argument-hint: "<name, e.g. work>"
disable-model-invocation: true
allowed-tools: Bash(claude-pet:*)
---

Add a new account called "$ARGUMENTS" to Claude Pet. If no name was given, ask for a short one like `work`.

First run `claude-pet list`. If it prints nothing, Claude Pet isn't set up yet, so ask the user to name their current account and run `claude-pet init <that name>` first.

Then run `claude-pet add $ARGUMENTS`. This saves the current logins and signs out of Claude Code and the desktop app.

Tell the user to log in to the new account in each app they use: in Claude Code, exit and run `claude` again, then `/login`. Claude Pet saves the new login automatically the next time they switch away.
