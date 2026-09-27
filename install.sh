#!/bin/bash
# Without the Claude Code plugin: builds and launches the desktop pet straight from this folder.
exec "$(cd "$(dirname "$0")" && pwd)/plugin/bin/claude-pet" install-pet
