#!/bin/bash
# Install as ~/.sleep — run by sleepwatcher during the pre-sleep grace window
# (macOS gives processes up to ~30s after kIOMessageSystemWillSleep before
# sleeping, and Bluetooth is still fully up during that window).
#
# Unpairs the devices when this Mac is being undocked (Magic accessories
# hold only one bond, so the arriving Mac must pair fresh — cross-Mac
# disconnect/connect was tested and does not work). Docked sleeps leave the
# devices paired. The display-watcher "removed" event can't be relied on to
# win the race against clamshell sleep — this hook runs in the guaranteed
# grace window.
#
# Setup:
#   brew install sleepwatcher
#   cp on-sleep.sh ~/.sleep && chmod +x ~/.sleep
#   brew services start sleepwatcher   # its default plist runs ~/.sleep on sleep

LOG_TAG=sleep-hook
source "${SMART_BT_KVM_LIB:-$HOME/bin/bt-actions.sh}" || exit 1

# Two signals, either one means "leaving": the display list shows no
# external, or the Mac is on battery — in the lid-closed undock the display
# list is stale (still shows the unplugged external), but power state flips
# instantly when the power-supplying display is pulled; see on_battery_power
# in bt-actions.sh.
if external_display_attached && ! on_battery_power; then
    log "docked sleep; leaving devices paired"
    exit 0
fi

log "undocking sleep; unpairing devices"
unpair_all
