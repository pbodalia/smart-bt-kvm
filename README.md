# smart-bt-kvm: auto unpair/pair of Bluetooth accessories between two Macs

Moves a Magic Trackpad/Keyboard between two Macs: the "leaving" Mac unpairs
on undock, the "arriving" Mac pairs on dock. One physical step remains —
power-cycle the accessory (or plug it in via cable for ~2s) near the
arriving Mac while its pair loop is retrying. Both Macs run the same
scripts; the docked/undocked gates decide which role each Mac plays.

It also carries a smaller, independent rule: **mute system output while any
of a named set of displays is attached**, and unmute once none of them are.
See [Muting on specific displays](#muting-on-specific-displays).

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
| `display-watcher.swift` + `display-event-handler.sh` + `com.smart-bt-kvm.plist` | External-display diff on `NSApplication.didChangeScreenParametersNotification` (AppKit run loop, launchd agent; `CGDisplayRegisterReconfigurationCallback` never fires for CLI processes — hardware-tested). Fires `added` / `removed` / `changed` | Awake either way: monitor unplugged → unpair; monitor plugged in → pair. Also catches the display that enumerates a few seconds after a hotplug-triggered wake, and drives the mute rule |
| `on-sleep.sh` (installed as `~/.sleep`) | System will-sleep via sleepwatcher | Leaving, clamshell — display unplug sleeps the machine before events fire |
| `on-wakeup.sh` (installed as `~/.wakeup`) | System wake via sleepwatcher, gated on external display attached | Arriving by waking an already-docked Mac (lid open, key press). Also re-applies the mute rule, covering a dock/undock that happened while asleep |
| `bt-actions.sh` | — | Shared library (config, gates, `unpair_all`, `pair_all` with retry + lock); sourced by the three scripts above |
| `bt-devices.conf` | — | Device IDs and `MUTE_DISPLAY_IDS`, installed to `~/.config/bt-devices.conf` |

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

- The event handler gates the *pairing* on "is an external display
  attached now", not on which display changed — closing the lid while
  docked or opening it undocked correctly does nothing. The mute rule is
  the exact opposite (it cares about one specific display), which is why
  the watcher diffs display identities rather than a presence flag and
  reports `changed` when the set changes without presence flipping.
- `pair_all` is two-branch: unpaired → `--pair` (needs the power-cycle),
  paired-but-disconnected → `--connect` (safe, no pairing risk).
  Concurrent triggers (wake hook + display-added event) are deduplicated
  by a pid-checked lock.
- Every gate decision logs its inputs (`display gate: ...`,
  `power source: ...`) to make the next misfire diagnosable from the log.

## Muting on specific displays

List displays in `MUTE_DISPLAY_IDS` in `~/.config/bt-devices.conf` and
system output is muted while **any** of them is attached, and unmuted once
**none** of them are. Leave the list empty and nothing in this section runs.

```sh
MUTE_DISPLAY_IDS=(
    "10ac:427c:3933384c"     # the monitor at the office
    "LG HDR 4K"              # the one at home, matched by name
)
```

Any-of, rather than one-per-rule, is what makes moving between desks behave:
unplugging the office monitor while a second listed display is still attached
keeps the Mac muted, and it only comes back when you are away from all of
them. The whole list is checked in one query, so the answer always comes from
a single consistent snapshot of what is plugged in.

To find the IDs, plug a display in and run:

```sh
~/bin/display-watcher --list
```

```
ID                        KIND      NAME
1e6d:5b11:1010101         external  LG HDR 4K
610:a050:0                builtin   Built-in Retina Display
```

Each ID is that display's EDID `vendor:model:serial` triple. **Do not use
`CGDirectDisplayID`** — the number most display tooling shows you — because
macOS reassigns it per session; the EDID triple survives replug and reboot.
If a triple ends in `:0` (the panel reports no serial) and you own two
identical monitors, put the `NAME` in the list instead; matching accepts
either, case-insensitively, and you can mix the two forms.

The unmute is deliberately conservative: it only ever reverses a mute these
scripts performed on an unmuted system, recorded in `/tmp/smart-bt-kvm.muted`.
Mute the Mac yourself before docking and unplugging the display will leave it
muted, because that mute was not ours to undo.

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
6. With `MUTE_DISPLAY_IDS` set: plug a listed display in and check the menu
   bar volume shows muted (`audio: a listed display is attached; muted
   output`); unplug it and check it comes back (`audio: no listed display
   attached; unmuted output`). Plugging in an *unlisted* external should log
   `audio: no match for: ...` and leave the volume alone. With two listed
   displays attached, unplugging one should leave it muted.

## Known caveats

- Muting uses AppleScript (`set volume output muted`), which acts on the
  **current output device**. If docking also switches output to the
  monitor's own HDMI/DisplayPort speakers, that device may report
  `missing value` for its mute state and ignore the change. The log says
  so (`audio: could not read mute state`, `audio: 'set volume ...' failed`);
  the fallback is to pick a different output device in Sound settings.
- Name matching (rather than the EDID triple) needs a WindowServer
  connection and sees only *active* displays, so it is best-effort: it
  will not resolve over ssh, and can miss a mirrored or sleeping panel.
  The triple has neither limitation — prefer it.
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
