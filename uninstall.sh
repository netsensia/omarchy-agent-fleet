#!/bin/bash
# Remove Agent Fleet's command, timers and bar widget. Leaves your config and the plugin checkout.
set -uo pipefail
ID=netsensia.agent-fleet
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"

systemctl --user disable --now agent-fleet.timer agent-fleet-limits.timer 2>/dev/null
rm -f "$UNIT_DIR"/agent-fleet.service "$UNIT_DIR"/agent-fleet.timer "$UNIT_DIR"/agent-fleet-limits.service "$UNIT_DIR"/agent-fleet-limits.timer
systemctl --user daemon-reload
[[ -L "$HOME/.local/bin/agent-fleet" ]] && rm -f "$HOME/.local/bin/agent-fleet"
command -v omarchy >/dev/null && omarchy plugin disable "$ID" >/dev/null 2>&1
if [[ -L "$HOME/.config/omarchy/plugins/$ID" ]]; then rm -f "$HOME/.config/omarchy/plugins/$ID"; fi
echo "Removed. Your settings (~/.config/agent-fleet) and data (~/.local/state/agent-fleet) were left in place."
echo "If you installed with 'omarchy plugin add', finish with: omarchy plugin remove $ID"
