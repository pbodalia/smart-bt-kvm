#!/bin/bash
# Shared functions for the smart-bt-kvm scripts — source it, don't run it.
# Installs to ~/bin/bt-actions.sh; callers may set SMART_BT_KVM_LIB to
# source it from elsewhere, and should set LOG_TAG first so log lines are
# attributable.
#
# Exits the sourcing script if config or blueutil is missing.

LOG=/tmp/smart-bt-kvm.log
PAIR_WINDOW_SECS=90             # how long pair_all keeps retrying — leaves
                                # time to power-cycle the accessory after docking
ATTEMPT_TIMEOUT=10              # kill a hung blueutil call after this long
RETRY_DELAY=3                   # pause between pair rounds
PAIR_LOCK=/tmp/smart-bt-kvm.pair.lock

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [${LOG_TAG:-smart-bt-kvm}] $*" >> "$LOG"
}

CONFIG="${BT_DEVICES_CONF:-$HOME/.config/bt-devices.conf}"
[ -f "$CONFIG" ] && source "$CONFIG"
if [ "${#DEVICE_IDS[@]}" -eq 0 ]; then
    log "no DEVICE_IDS configured; copy bt-devices.conf to $CONFIG and edit it"
    exit 1
fi

# Homebrew path differs by architecture; fall back through both.
BLUEUTIL="$(command -v blueutil || true)"
[ -x "$BLUEUTIL" ] || BLUEUTIL=/opt/homebrew/bin/blueutil
[ -x "$BLUEUTIL" ] || BLUEUTIL=/usr/local/bin/blueutil
if [ ! -x "$BLUEUTIL" ]; then
    log "blueutil not found; install with: brew install blueutil"
    exit 1
fi

# "display-watcher --status" queries CGGetOnlineDisplayList live
# (milliseconds; sleeping displays stay in the online list). Replaces
# system_profiler here, which was slow and reported stale/empty display
# info during sleep/wake transitions — that made the sleep hook see "no
# external display" while docked. Exit 0 = external attached, 1 = none,
# >1 = query failed (abort rather than guess).
DISPLAY_STATUS_BIN="${SMART_BT_KVM_DISPLAY_STATUS:-$HOME/bin/display-watcher}"

external_display_attached() {
    local out rc
    out=$("$DISPLAY_STATUS_BIN" --status 2>/dev/null)
    rc=$?
    if [ "$rc" -gt 1 ]; then
        log "display gate: '$DISPLAY_STATUS_BIN --status' failed (exit $rc); aborting"
        exit 1
    fi
    log "display gate: $out"
    return "$rc"
}

# Detects the lid-closed undock at sleep time. The display list can't:
# WindowServer defers the reconfiguration until wake, so the unplugged
# display is still listed. The pmset sleep-reason log can't either: powerd
# writes the "Entering Sleep" entry only after the sleep proceeds, i.e.
# after this hook has returned (confirmed: a 15s poll never saw it).
#
# Power source can: clamshell mode requires AC power to stay awake, so a
# lid-closed Mac heading to sleep on battery means the power-supplying
# display was just unplugged. Assumes the external display/dock charges
# the Mac (confirmed by "Using Batt" in the real undock's pmset log entry).
#
# The flip to battery lags the physical unplug by a few seconds (USB-C PD
# renegotiation / SMC reporting — observed: hook read AC ~1s after unplug,
# powerd recorded battery ~5s after), so poll rather than read once.
# Unlike the display list and the sleep-reason log, power state is
# hardware-level and updates while sleepwatcher holds the sleep open.
# Timeout means genuinely still on AC -> docked; costs those sleeps ~10s.
on_battery_power() {
    local start ps
    start=$(date +%s)
    while :; do
        ps=$(pmset -g ps 2>/dev/null | head -1)
        if echo "$ps" | grep -q "Battery Power"; then
            log "power source: battery (after $(( $(date +%s) - start ))s)"
            return 0
        fi
        if [ $(( $(date +%s) - start )) -ge 10 ]; then
            log "power source: still AC after 10s (${ps:-unknown}); assuming docked"
            return 1
        fi
        sleep 1
    done
}

# Guard against a blocked blueutil call eating a whole retry window (macOS
# has no timeout(1) out of the box).
run_with_timeout() {
    local secs=$1
    shift
    "$@" &
    local pid=$!
    ( sleep "$secs" && kill "$pid" 2>/dev/null ) &
    local killer=$!
    wait "$pid"
    local rc=$?
    kill "$killer" 2>/dev/null
    return "$rc"
}

is_connected() {
    [ "$("$BLUEUTIL" --is-connected "$1" 2>/dev/null)" = "1" ]
}

is_paired() {
    "$BLUEUTIL" --paired 2>/dev/null | grep -qi "$1"
}

unpair_all() {
    local id
    for id in "${DEVICE_IDS[@]}"; do
        if "$BLUEUTIL" --unpair "$id" >> "$LOG" 2>&1; then
            log "unpaired $id"
        else
            log "unpair of $id failed (exit $?)"
        fi
    done
}

# Acquires the devices, retrying for up to PAIR_WINDOW_SECS. Two branches
# per device: not paired -> --pair, which only succeeds while the accessory
# is freshly power-cycled (known blueutil issue; the window leaves time to
# flick the switch after docking); paired but disconnected -> --connect,
# which is safe and doesn't risk disturbing an existing pairing. A
# pid-checked lock keeps concurrent triggers (wake hook + display-added
# event) from running duplicate loops.
pair_all() {
    if ! mkdir "$PAIR_LOCK" 2>/dev/null; then
        local oldpid
        oldpid=$(cat "$PAIR_LOCK/pid" 2>/dev/null)
        if [ -n "$oldpid" ] && kill -0 "$oldpid" 2>/dev/null; then
            log "pair loop already running (pid $oldpid); skipping"
            return 0
        fi
        rm -rf "$PAIR_LOCK"
        mkdir "$PAIR_LOCK" 2>/dev/null || return 0
    fi
    echo $$ > "$PAIR_LOCK/pid"
    trap 'rm -rf "$PAIR_LOCK"' EXIT

    local deadline id all_done
    deadline=$(( $(date +%s) + PAIR_WINDOW_SECS ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        all_done=1
        for id in "${DEVICE_IDS[@]}"; do
            if ! is_paired "$id"; then
                all_done=0
                if run_with_timeout "$ATTEMPT_TIMEOUT" "$BLUEUTIL" --pair "$id" >> "$LOG" 2>&1; then
                    log "paired $id"
                fi
            elif ! is_connected "$id"; then
                all_done=0
                if run_with_timeout "$ATTEMPT_TIMEOUT" "$BLUEUTIL" --connect "$id" >> "$LOG" 2>&1; then
                    log "connected $id"
                fi
            fi
        done
        if [ "$all_done" -eq 1 ]; then
            log "all devices paired and connected"
            return 0
        fi
        sleep "$RETRY_DELAY"
    done

    for id in "${DEVICE_IDS[@]}"; do
        if ! is_paired "$id"; then
            log "gave up on $id after ${PAIR_WINDOW_SECS}s (still unpaired — power-cycle it near this Mac and re-dock or wake again)"
        elif ! is_connected "$id"; then
            log "gave up on $id after ${PAIR_WINDOW_SECS}s (paired but not connected)"
        fi
    done
    return 1
}

# --- audio follows a set of displays ----------------------------------
#
# MUTE_DISPLAY_IDS (in bt-devices.conf, empty = feature off) lists displays
# by EDID triple or name — run `display-watcher --list` with one plugged in
# to get the values. System output is muted while ANY listed display is
# attached, and unmuted once NONE of them are. Listing several is how you
# cover more than one desk without caring which one you are at.
#
# "Unmuted" means only undoing our own work: the marker file records a mute
# this script performed on an unmuted system, so a mute the user set
# themselves is never silently lifted on disconnect.
MUTE_MARKER=/tmp/smart-bt-kvm.muted

# "Is any of these displays attached?" — the whole list goes in one call so
# the answer comes from a single display snapshot. Deliberately softer than
# external_display_attached, which aborts the script on a failed query: the
# audio rule is bolted onto the pairing logic and must never take it down.
# 0 = at least one attached, 1 = none, 2 = unknown.
any_display_attached() {
    local out rc
    out=$("$DISPLAY_STATUS_BIN" --has "$@" 2>/dev/null)
    rc=$?
    if [ "$rc" -gt 1 ]; then
        log "audio: '$DISPLAY_STATUS_BIN --has $*' failed (exit $rc); leaving volume alone"
        return 2
    fi
    log "audio: $out"
    return "$rc"
}

# 0 = muted, 1 = unmuted, 2 = unreadable. Some output devices (notably
# HDMI/DisplayPort audio on the monitor itself) report "missing value"
# rather than a boolean, which is why 2 is a real case and not paranoia.
output_muted() {
    local v
    v=$(osascript -e 'output muted of (get volume settings)' 2>/dev/null)
    case "$v" in
        true)  return 0 ;;
        false) return 1 ;;
        *)     log "audio: could not read mute state (got '${v:-<nothing>}')"; return 2 ;;
    esac
}

set_output_muted() {            # $1 = true | false
    if osascript -e "set volume output muted $1" >> "$LOG" 2>&1; then
        return 0
    fi
    log "audio: 'set volume output muted $1' failed"
    return 1
}

# Idempotent: re-runnable on every display event and at wake, which is how
# the undock-while-asleep case gets unmuted.
sync_audio_for_display() {
    [ "${#MUTE_DISPLAY_IDS[@]}" -gt 0 ] || return 0

    local attached muted
    any_display_attached "${MUTE_DISPLAY_IDS[@]}"; attached=$?
    [ "$attached" -eq 2 ] && return 0

    output_muted; muted=$?

    if [ "$attached" -eq 0 ]; then
        if [ "$muted" -eq 0 ]; then
            log "audio: a listed display is attached; output already muted"
            return 0
        fi
        set_output_muted true || return 1
        if [ "$muted" -eq 1 ]; then
            : > "$MUTE_MARKER"
            log "audio: a listed display is attached; muted output"
        else
            # We changed something we couldn't read first, so we can't
            # promise to put it back — mute, but don't claim the unmute.
            log "audio: a listed display is attached; muted output (prior state unknown, will not auto-unmute)"
        fi
    else
        if [ ! -f "$MUTE_MARKER" ]; then
            log "audio: no listed display attached; no mute of ours to undo"
            return 0
        fi
        set_output_muted false || return 1
        rm -f "$MUTE_MARKER"
        log "audio: no listed display attached; unmuted output"
    fi
}
