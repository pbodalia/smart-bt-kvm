#!/bin/bash
# Invoked by display-watcher with "added", "removed" or "changed" on every
# display configuration event. Installs to ~/bin/display-event-handler.sh.
#
# Gating the pairing on whether an external display remains attached
# (rather than on which display changed) means: unplugging the external
# triggers the unpair, but closing the lid while docked (built-in display
# removed, external still there) correctly does nothing. The audio rule is
# the opposite — it cares about one named display — so it re-evaluates on
# every event, "changed" included.

LOG_TAG=display-event
source "${SMART_BT_KVM_LIB:-$HOME/bin/bt-actions.sh}" || exit 1

case "$1" in
    added|removed|changed) ;;
    *)
        echo "usage: $0 added|removed|changed" >&2
        exit 2
        ;;
esac

# Before the pairing branch: pair_all blocks for up to PAIR_WINDOW_SECS,
# and muting should not wait that out.
sync_audio_for_display

case "$1" in
    removed)
        if external_display_attached; then
            log "display removed but an external is still attached; ignoring"
            exit 0
        fi
        log "external display removed; unpairing devices"
        unpair_all
        ;;
    added)
        if ! external_display_attached; then
            log "display added but no external attached (built-in re-enabled?); ignoring"
            exit 0
        fi
        log "external display added; acquiring devices"
        pair_all
        ;;
    changed)
        # The set of externals changed without flipping presence — still
        # docked, so the devices stay where they are.
        log "external display set changed while still docked; no pairing action"
        ;;
esac
