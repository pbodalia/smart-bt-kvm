// Display watcher + status/identity queries for smart-bt-kvm.
//
// Watch mode (default): observes NSApplication.didChangeScreenParametersNotification
// via an AppKit run loop and invokes the handler script when the set of
// attached external displays changes. AppKit is used because
// CGDisplayRegisterReconfigurationCallback never delivers callbacks to a
// plain CLI process on this macOS version — verified on real hardware:
// zero invocations (any flags) even when run from Terminal in the user's
// session. The notification doesn't say what changed, so the watcher diffs
// the external displays itself; resolution/arrangement changes are ignored
// naturally.
//
// The handler is invoked with:
//   added    — no external before, at least one now
//   removed  — external(s) before, none now
//   changed  — the set changed but presence didn't flip (one external
//              swapped for another, or one of several unplugged). The
//              pairing logic ignores this; the per-display audio rule
//              does not, which is why it is reported at all.
//
// Status mode (--status): prints "external=N builtin=N asleep=N" and exits
// 0 if an external display is attached, 1 if not, 2 on query failure.
// The shell gates call this instead of system_profiler, which proved
// unreliable at decision time (slow, and stale/empty during sleep/wake
// transitions). CGGetOnlineDisplayList answers live and works fine as a
// one-shot query — it is only the CG *callback* delivery that is broken.
//
// List mode (--list): prints every online display with the ID to put in
// bt-devices.conf. Run it while the display you care about is plugged in.
//
// Has mode (--has <id>...): exits 0 if ANY of the given displays is
// online, 1 if none are, 2 on query failure — the gate behind
// MUTE_DISPLAY_IDS. Taking the whole list in one call keeps the answer to
// a single CGGetOnlineDisplayList snapshot; asking once per ID could
// straddle a reconfiguration and see a display in neither call.
//
// Build:   ./build.sh   (swiftc -O display-watcher.swift -o ./bin/display-watcher)
// Install: ./install.sh (watch mode runs under com.smart-bt-kvm.plist;
//          --status / --has are called by bt-actions.sh)
//
// Usage: display-watcher [--status | --list | --has <id>... | handler-path]
//   handler defaults to ~/bin/display-event-handler.sh; it is invoked
//   asynchronously with a single argument, the event name above.

import AppKit
import CoreGraphics
import Foundation

// A display's identity. vendor/model/serial come from the EDID and are
// stable across replug and reboot, unlike CGDirectDisplayID, which macOS
// reassigns per session and so must never be written into config.
// Caveat: plenty of panels report serial 0, so two identical monitors can
// share a key — match those by name instead.
struct DisplayInfo {
    let id: CGDirectDisplayID
    let isBuiltin: Bool
    let isAsleep: Bool
    let vendor: UInt32
    let model: UInt32
    let serial: UInt32

    var key: String { String(format: "%x:%x:%x", vendor, model, serial) }
}

func onlineDisplays() -> [DisplayInfo]? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
        return nil
    }
    return ids.prefix(Int(count)).map {
        DisplayInfo(id: $0,
                    isBuiltin: CGDisplayIsBuiltin($0) != 0,
                    isAsleep: CGDisplayIsAsleep($0) != 0,
                    vendor: CGDisplayVendorNumber($0),
                    model: CGDisplayModelNumber($0),
                    serial: CGDisplaySerialNumber($0))
    }
}

// Human-readable names live on NSScreen, not CoreGraphics. That means a
// WindowServer connection, and NSScreen lists only *active* displays — so
// names are best-effort decoration (empty over ssh, or for a mirrored or
// sleeping panel). Everything load-bearing keys off the EDID triple, and
// this is only consulted when it is actually needed.
func displayNames() -> [CGDirectDisplayID: String] {
    var names: [CGDirectDisplayID: String] = [:]
    for screen in NSScreen.screens {
        if let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            names[CGDirectDisplayID(num.uint32Value)] = screen.localizedName
        }
    }
    return names
}

// An ID is either the EDID triple or a display's name; only the latter
// needs the NSScreen lookup, so recognise the triple by shape first.
func looksLikeKey(_ s: String) -> Bool {
    let parts = s.split(separator: ":")
    return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isHexDigit) }
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(2)
}

let args = CommandLine.arguments

switch args.count > 1 ? args[1] : "" {
case "--status":
    guard let displays = onlineDisplays() else { fail("CGGetOnlineDisplayList failed") }
    let external = displays.filter { !$0.isBuiltin }.count
    let builtin = displays.count - external
    let asleep = displays.filter(\.isAsleep).count
    print("external=\(external) builtin=\(builtin) asleep=\(asleep)")
    exit(external > 0 ? 0 : 1)

case "--list":
    guard let displays = onlineDisplays() else { fail("CGGetOnlineDisplayList failed") }
    let names = displayNames()
    let rows = displays.map {
        ($0.key, $0.isBuiltin ? "builtin" : "external", names[$0.id] ?? "")
    }
    let width = max(24, rows.map(\.0.count).max() ?? 0)
    print("ID".padding(toLength: width, withPad: " ", startingAt: 0) + "  KIND      NAME")
    for (key, kind, name) in rows {
        print(key.padding(toLength: width, withPad: " ", startingAt: 0)
              + "  " + kind.padding(toLength: 8, withPad: " ", startingAt: 0)
              + "  " + name)
    }
    print("")
    print("Put the ID (or the NAME, if the ID ends in :0 and you own two identical")
    print("displays) in ~/.config/bt-devices.conf under MUTE_DISPLAY_IDS.")
    exit(0)

case "--has":
    guard args.count > 2 else { fail("usage: display-watcher --has <id> [<id>...]") }
    let wanted = args[2...].map { $0.lowercased() }
    guard let displays = onlineDisplays() else { fail("CGGetOnlineDisplayList failed") }
    // Names cost a WindowServer round trip and are unavailable in some
    // contexts; skip them entirely unless some ID actually needs one.
    let names = wanted.allSatisfy(looksLikeKey) ? [:] : displayNames()
    for d in displays {
        let name = names[d.id]?.lowercased()
        if wanted.contains(d.key) || (name != nil && wanted.contains(name!)) {
            print("match: \(d.key) \(d.isBuiltin ? "builtin" : "external") \(names[d.id] ?? "")")
            exit(0)
        }
    }
    print("no match for: \(args[2...].joined(separator: ", "))")
    exit(1)

default:
    break
}

let handlerPath = args.count > 1
    ? args[1]
    : NSHomeDirectory() + "/bin/display-event-handler.sh"

func logLine(_ msg: String) {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    print("\(fmt.string(from: Date())) [display-watcher] \(msg)")
}

func runHandler(_ event: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/bash")
    p.arguments = [handlerPath, event]
    do {
        try p.run() // don't wait — the "added" handler may retry for a while
    } catch {
        logLine("failed to run \(handlerPath): \(error)")
    }
}

// Sorted so the comparison is order-insensitive, and a list (not a Set) so
// that unplugging one of two identical displays still reads as a change.
func externalKeys(_ displays: [DisplayInfo]) -> [String] {
    displays.filter { !$0.isBuiltin }.map(\.key).sorted()
}

// launchd redirects stdout to the shared log file; without this, output
// is block-buffered and may never appear, making a live watcher look dead.
setvbuf(stdout, nil, _IONBF, 0)

var lastKeys = externalKeys(onlineDisplays() ?? [])

NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil,
    queue: .main
) { _ in
    // A failed query is not "no displays" — holding the previous state is
    // the safe reading, and the next event re-checks anyway.
    guard let displays = onlineDisplays() else {
        logLine("screen parameters changed but the display query failed; ignoring")
        return
    }
    let now = externalKeys(displays)
    logLine("screen parameters changed; external: [\(lastKeys.joined(separator: " "))] -> [\(now.joined(separator: " "))]")
    guard now != lastKeys else { return }
    let was = lastKeys
    lastKeys = now
    if was.isEmpty {
        runHandler("added")
    } else if now.isEmpty {
        runHandler("removed")
    } else {
        runHandler("changed")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // no dock icon, no app switcher entry
logLine("started (AppKit watcher), external=[\(lastKeys.joined(separator: " "))], handler: \(handlerPath)")
app.run()
