#!/bin/bash
# First-time install and update refresh. Safe to re-run after any change:
# rebuilds the binary, refreshes the installed copies, and restarts the
# launchd agent so the new binary is picked up. Never overwrites an
# existing ~/.config/bt-devices.conf.
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(uname)" != "Darwin" ]; then
    echo "this installs launchd/sleepwatcher hooks — macOS only" >&2
    exit 1
fi

LABEL=com.smart-bt-kvm
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"

./build.sh

mkdir -p "$HOME/bin" "$HOME/.config" "$HOME/Library/LaunchAgents"

install -m 755 ./bin/display-watcher "$HOME/bin/display-watcher"
install -m 755 display-event-handler.sh "$HOME/bin/display-event-handler.sh"
install -m 644 bt-actions.sh "$HOME/bin/bt-actions.sh"
install -m 755 on-sleep.sh "$HOME/.sleep"
install -m 755 on-wakeup.sh "$HOME/.wakeup"

if [ ! -f "$HOME/.config/bt-devices.conf" ]; then
    install -m 644 bt-devices.conf "$HOME/.config/bt-devices.conf"
    echo "NOTE: first install — edit ~/.config/bt-devices.conf and set DEVICE_IDS (see: blueutil --paired)"
elif ! grep -q MUTE_DISPLAY_IDS "$HOME/.config/bt-devices.conf"; then
    # Config files are never overwritten, so a knob added after an install
    # would otherwise stay invisible to anyone already running this.
    echo "NOTE: ~/.config/bt-devices.conf predates MUTE_DISPLAY_IDS (mute output while"
    echo "      any listed display is attached). To use it, copy the block from"
    echo "      bt-devices.conf; list your displays with: $HOME/bin/display-watcher --list"
fi

# Bake this machine's home dir into the plist (launchd doesn't expand ~).
sed "s|<string>/Users/[^<]*/bin/display-watcher</string>|<string>$HOME/bin/display-watcher</string>|" \
    "$LABEL.plist" > "$PLIST_DST"

# Load-or-reload: bootout is a no-op error if not loaded; bootstrap then
# starts a fresh watcher process (RunAtLoad), which also covers picking up
# a rebuilt binary on updates.
uid=$(id -u)
launchctl bootout "gui/$uid/$LABEL" 2>/dev/null || true
sleep 1
launchctl bootstrap "gui/$uid" "$PLIST_DST"

# Self-check: watch mode must actually be running, or the lid-open
# unplug/replug path has no coverage.
sleep 2
if launchctl print "gui/$uid/$LABEL" 2>/dev/null | grep -q "state = running"; then
    echo "display-watcher agent is running"
else
    echo "WARNING: display-watcher agent is NOT running —"
    echo "  inspect: launchctl print gui/$uid/$LABEL"
    echo "  and check /tmp/smart-bt-kvm.log for a 'display-watcher started' line"
fi

command -v blueutil >/dev/null || echo "WARNING: blueutil not found — brew install blueutil"
if command -v brew >/dev/null; then
    if ! brew services list 2>/dev/null | grep "^sleepwatcher" | grep -q started; then
        brew services start sleepwatcher \
            || echo "WARNING: could not start sleepwatcher — brew install sleepwatcher"
    fi
else
    echo "WARNING: Homebrew not found — install blueutil and sleepwatcher manually"
fi

echo "done — watch the log with: tail -f /tmp/smart-bt-kvm.log"
