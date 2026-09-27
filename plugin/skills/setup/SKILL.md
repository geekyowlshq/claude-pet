---
name: setup
description: Set up Claude Pet — build the desktop pet and save the account you're logged into now. Use when the user wants to install or set up Claude Pet.
argument-hint: "[name for your current account, e.g. personal]"
disable-model-invocation: true
allowed-tools: Bash(claude-pet:*)
---

Set up Claude Pet on this Mac.

1. Run `claude-pet install-pet`. If it says macOS only, or the command can't run at all (Windows or Linux), tell the user Claude Pet works on macOS only for now and Windows and Linux support is planned, then stop. Otherwise it builds the desktop pet into ~/Applications and opens it. If it says Apple's command line tools are missing, tell the user to run `xcode-select --install`, then try again. If the Swift build fails, show the error and offer to fix the source in the plugin's `pet/ClaudePet.swift`.
2. Run `claude-pet list`. If it prints nothing, the current login hasn't been saved yet. Use "$ARGUMENTS" as the name if it was given. Otherwise ask the user for a short name (up to 10 characters) for the account they're logged into right now (like `personal`). Then run `claude-pet init <name>`.
3. Tell the user, briefly:
   - Hover the pet and click **+** (or run `/claude-pet:add work`) to add their other account as a profile. Claude Code and the desktop app sign out, they log in once in each, and Claude Pet remembers it.
   - After that, hovering the pet shows one small pet per profile; click one to switch. The gear (or a right-click) opens the menu: Manage profiles to pick each profile's animal and colour, and a size slider.
   - The pet switches Claude Code and the Claude desktop app. claude.ai in Chrome isn't switched; Claude Pet for Chrome is coming soon.
