#!/bin/bash
# Install as ~/.wakeup — run by sleepwatcher when the system wakes.
#
# Also re-applies the MUTE_DISPLAY_ID audio rule, which covers docking or
# undocking a Mac that was asleep at the time.
#
# Acquires the devices when waking docked (external display attached):
# --pair for unpaired ones (power-cycle the accessory near this Mac during
# the retry window), --connect for paired-but-disconnected ones. If the
# wake was caused by plugging the display in, the display may not be
# enumerated yet when this gate runs; that case is covered by the
# display-watcher "added" event, which fires once enumeration completes.
# The pair lock in bt-actions.sh keeps the two triggers from running
# duplicate loops.
#
# Setup (sleepwatcher's default plist already runs ~/.wakeup on wake):
#   cp on-wakeup.sh ~/.wakeup && chmod +x ~/.wakeup

LOG_TAG=wake-hook
source "${SMART_BT_KVM_LIB:-$HOME/bin/bt-actions.sh}" || exit 1

# Ahead of the pairing gate, which returns early when undocked — and an
# undock that happened while this Mac was asleep is precisely when the
# mute needs undoing, since no display event fired to do it.
sync_audio_for_display

if ! external_display_attached; then
    log "woke with no external display; not pairing"
    exit 0
fi

log "woke docked; acquiring ${DEVICE_IDS[*]}"
pair_all
