#!/bin/bash
# Invoked by display-watcher with "added" or "removed" on every display
# configuration event. Installs to ~/bin/display-event-handler.sh.
#
# Gating on whether an external display remains attached (rather than on
# which display changed) means: unplugging the external triggers the
# unpair, but closing the lid while docked (built-in display removed,
# external still there) correctly does nothing.

LOG_TAG=display-event
source "${SMART_BT_KVM_LIB:-$HOME/bin/bt-actions.sh}" || exit 1

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
    *)
        echo "usage: $0 added|removed" >&2
        exit 2
        ;;
esac
