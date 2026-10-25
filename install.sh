#!/usr/bin/env bash
# Installs the /redact-quota command and its engine script into the user's
# global OpenCode config directory.
set -euo pipefail
mkdir -p "$HOME/.config/opencode/commands" "$HOME/.config/opencode/bin"
cp commands/redact-quota.md "$HOME/.config/opencode/commands/redact-quota.md"
cp redact-quota.sh "$HOME/.config/opencode/bin/redact-quota.sh"
chmod +x "$HOME/.config/opencode/bin/redact-quota.sh"
echo "installed /redact-quota to ~/.config/opencode"
