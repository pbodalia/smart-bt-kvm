# smart-bt-kvm: auto unpair/pair of Bluetooth accessories between two Macs

Moves a Magic Trackpad/Keyboard between two Macs: the "leaving" Mac unpairs
on undock, the "arriving" Mac pairs on dock. One physical step remains —
power-cycle the accessory (or plug it in via cable for ~2s) near the
arriving Mac while its pair loop is retrying. Both Macs run the same
scripts; the docked/undocked gates decide which role each Mac plays.

## Why unpair/pair, not disconnect/connect

Tested on real hardware and worth remembering:

- Magic accessories hold **one Bluetooth bond**. Cross-Mac
  disconnect/connect (disconnect on Mac A, connect from Mac B's menu)
  **does not work** — Mac B needs a fresh pairing, which invalidates
  Mac A's. So the leaving Mac unpairs to clean up, and the arriving Mac
  pairs fresh.
- `blueutil --pair` only succeeds while the accessory is freshly
  power-cycled (known blueutil issue) — hence the retry window
  (`PAIR_WINDOW_SECS`, 90s) and the physical toggle step.

## How each trigger works

| File | Trigger | Covers |
|---|---|---|
| `display-watcher.swift` + `display-event-handler.sh` + `com.smart-bt-kvm.plist` | External-display presence diff on `NSApplication.didChangeScreenParametersNotification` (AppKit run loop, launchd agent; `CGDisplayRegisterReconfigurationCallback` never fires for CLI processes — hardware-tested) | Awake either way: monitor unplugged → unpair; monitor plugged in → pair. Also catches the display that enumerates a few seconds after a hotplug-triggered wake |
| `on-sleep.sh` (installed as `~/.sleep`) | System will-sleep via sleepwatcher | Leaving, clamshell — display unplug sleeps the machine before events fire |
| `on-wakeup.sh` (installed as `~/.wakeup`) | System wake via sleepwatcher, gated on external display attached | Arriving by waking an already-docked Mac (lid open, key press) |
| `bt-actions.sh` | — | Shared library (config, gates, `unpair_all`, `pair_all` with retry + lock); sourced by the three scripts above |
| `bt-devices.conf` | — | Device IDs, installed to `~/.config/bt-devices.conf` |

The sleep hook's "am I being undocked?" gate is the hard-won part. At
will-sleep time, display state lies in every queryable form
(hardware-tested, in order of failure): `system_profiler` is slow and
stale; the CoreGraphics display list still contains the unplugged display
because WindowServer defers the reconfiguration until wake; and pmset's
sleep-reason log entry is only written after the sleep proceeds. What
works: **power source**. Clamshell mode requires AC, and the
display/dock is what powers the Mac — so the hook polls `pmset -g ps`
for up to 10s and treats a flip to battery (lags the unplug by ~2-5s due
to USB-C PD renegotiation) as "undocking". Docked lid-closed sleeps pay
the 10s timeout; that delay is invisible in practice.

Other design notes:

- The event handler gates on "is an external display attached now", not
  on which display changed — closing the lid while docked or opening it
  undocked correctly does nothing.
- `pair_all` is two-branch: unpaired → `--pair` (needs the power-cycle),
  paired-but-disconnected → `--connect` (safe, no pairing risk).
  Concurrent triggers (wake hook + display-added event) are deduplicated
  by a pid-checked lock.
- Every gate decision logs its inputs (`display gate: ...`,
  `power source: ...`) to make the next misfire diagnosable from the log.

## Install (on both Macs)

```sh
brew install blueutil sleepwatcher
./install.sh
```

`install.sh` works for both first-time installs and refreshes after any
update: it runs `build.sh` (compiles `display-watcher`; needs Xcode
Command Line Tools), copies the binary + scripts to `~/bin/`, installs the
hooks as `~/.sleep` / `~/.wakeup`, bakes your home path into the launchd
plist, reloads the agent (so a rebuilt binary is picked up), and verifies
the agent is actually running. On first install it seeds
`~/.config/bt-devices.conf` from the template — edit it and set
`DEVICE_IDS` (see `blueutil --paired`); re-runs never overwrite it. It
also starts the sleepwatcher service if it isn't running.

All scripts source `~/.config/bt-devices.conf` via `bt-actions.sh`
(override paths with `BT_DEVICES_CONF` / `SMART_BT_KVM_LIB` /
`SMART_BT_KVM_DISPLAY_STATUS`) and exit with an error if it's missing.
Each device is handled independently; a failure on one doesn't stop the
others.

Everything logs to `/tmp/smart-bt-kvm.log`, prefixed `[display-event]` /
`[sleep-hook]` / `[wake-hook]`.

## The switch, in practice

1. Undock Mac A (unplug the display, lid open or closed). Log shows
   `undocking sleep; unpairing devices` (or the `[display-event]`
   equivalent if awake).
2. Dock Mac B and wake it. Its pair loop starts retrying
   (`woke docked; acquiring ...`).
3. Flick each accessory's power switch off/on (or cable-plug ~2s) within
   the 90s window. Log shows `paired <id>`.

## Verify after installing

1. `install.sh` reports "display-watcher agent is running".
2. Unplug the monitor lid-open: `[display-event] external display
   removed; unpairing` within a second. Replug: acquiring.
3. Close the lid while docked (on AC): log shows the removed event being
   ignored / `docked sleep; leaving devices paired`.
4. Lid-closed undock: `power source: battery (after ~2-5s)` then
   unpairing — this is the case that took four attempts to detect.
5. Full round trip between both Macs, watching `/tmp/smart-bt-kvm.log`
   on both sides.

## Known caveats

- `blueutil` needs Bluetooth privacy permission. Under launchd/sleepwatcher
  the prompt may not appear — if it works in Terminal but fails silently
  from the agents, check System Settings → Privacy & Security → Bluetooth
  (the responsible process may be `display-watcher` or `bash`).
- The undock detection assumes the external display/dock **charges the
  Mac**. Docked with a separate wall charger and a non-charging display
  cable, the lid-closed undock would read as "AC + display listed" and be
  missed. The `power source:` log line will show it if this ever bites.
- If the monitor is unplugged from a Mac that is *already asleep*, nothing
  fires until its next wake (the deferred display-removed event arrives
  then and unpairs). Until that wake the sleeping Mac holds a stale bond —
  disable "Allow Bluetooth devices to wake this computer" on both Macs so
  it can't grab the accessory back or get woken by it.
- The accessory-side bond only moves on a fresh pairing, so if the pair
  window expires before you power-cycle, just re-dock/wake again (or run
  `~/bin/display-event-handler.sh added` manually) and flick the switch.
