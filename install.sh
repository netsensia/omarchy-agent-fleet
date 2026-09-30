#!/bin/bash
# Install Agent Fleet: the `agent-fleet` command, its systemd user timers, and the Omarchy bar widget.
# Safe to re-run (e.g. after `omarchy plugin update netsensia.agent-fleet`).
set -euo pipefail

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ID=netsensia.agent-fleet
PLUGIN_DIR="$HOME/.config/omarchy/plugins/$ID"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

say() { printf '\033[1m%s\033[0m\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }

command -v python3 >/dev/null || { echo "agent-fleet needs python3" >&2; exit 1; }
command -v herdr >/dev/null || warn "herdr not found on PATH: agent-fleet lists herdr agents, so the widget will be empty without it."
command -v omarchy >/dev/null || warn "omarchy not found: the command and timers will install, but there is no bar to put the widget in."

say "Installing the agent-fleet command"
mkdir -p "$HOME/.local/bin"
ln -sfn "$DIR/bin/agent-fleet" "$HOME/.local/bin/agent-fleet"

say "Installing systemd user timers"
mkdir -p "$UNIT_DIR"
cp "$DIR"/systemd/agent-fleet*.service "$DIR"/systemd/agent-fleet*.timer "$UNIT_DIR/"
systemctl --user daemon-reload
systemctl --user enable --now agent-fleet.timer agent-fleet-limits.timer >/dev/null

say "Collecting a first snapshot"
"$HOME/.local/bin/agent-fleet" limits || true
"$HOME/.local/bin/agent-fleet" collect

if command -v omarchy >/dev/null; then
  if [[ "$(readlink -f "$PLUGIN_DIR" 2>/dev/null)" != "$DIR" ]]; then
    if [[ -e "$PLUGIN_DIR" ]]; then
      warn "$PLUGIN_DIR exists and is not this checkout; leaving it alone."
    else
      say "Linking the widget into Omarchy's plugin folder"
      mkdir -p "$(dirname "$PLUGIN_DIR")"
      ln -s "$DIR" "$PLUGIN_DIR"
    fi
  fi
  say "Enabling the bar widget"
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  sleep 1
  omarchy plugin enable "$ID" >/dev/null || warn "could not enable $ID; try: omarchy plugin enable $ID"
  if omarchy-shell shell listPlugins 2>/dev/null | grep -q '"omarchy.agents"'; then
    omarchy bar move "$ID" --after omarchy.agents >/dev/null 2>&1 || true
  fi
fi

say "Done."
echo "  Terminal view:  agent-fleet"
echo "  Try it with sample data:  agent-fleet demo   (and agent-fleet demo --off to go back)"
echo "  Optional settings: cp $DIR/config.example.json ~/.config/agent-fleet/config.json"
