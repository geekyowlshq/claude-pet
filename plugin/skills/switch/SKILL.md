---
name: switch
description: Switch Claude accounts with Claude Pet (e.g. "switch to my work account"). Use when the user asks to change, swap or switch their Claude account.
argument-hint: "[account name — leave empty for the next one]"
allowed-tools: Bash(claude-pet:*)
---

If "$ARGUMENTS" is empty, run `claude-pet next`. Otherwise run `claude-pet use $ARGUMENTS`. If the name doesn't match, run `claude-pet list` and pick the closest account the user meant.

Report which account is active in one line. If Claude Code switched, remind the user that this session still runs on the old account, so they should exit and start `claude` again to use the new one.
