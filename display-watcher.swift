// Display watcher + status query for smart-bt-kvm.
//
// Watch mode (default): observes NSApplication.didChangeScreenParametersNotification
// via an AppKit run loop and invokes the handler script with "added" /
// "removed" when external-display presence changes. AppKit is used because
// CGDisplayRegisterReconfigurationCallback never delivers callbacks to a
// plain CLI process on this macOS version — verified on real hardware:
// zero invocations (any flags) even when run from Terminal in the user's
// session. The notification doesn't say what changed, so the watcher diffs
// external-display presence across events; resolution/arrangement changes
// are ignored naturally.
//
// Status mode (--status): prints "external=N builtin=N asleep=N" and exits
// 0 if an external display is attached, 1 if not, 2 on query failure.
// The shell gates call this instead of system_profiler, which proved
// unreliable at decision time (slow, and stale/empty during sleep/wake
// transitions). CGGetOnlineDisplayList answers live and works fine as a
// one-shot query — it is only the CG *callback* delivery that is broken.
//
// Build:   ./build.sh   (swiftc -O display-watcher.swift -o ./bin/display-watcher)
// Install: ./install.sh (watch mode runs under com.smart-bt-kvm.plist;
//          --status is called by bt-actions.sh)
//
// Usage: display-watcher [--status | handler-path]
//   handler defaults to ~/bin/display-event-handler.sh; it is invoked
//   asynchronously with a single argument, "added" or "removed".

import AppKit
import CoreGraphics
import Foundation

func queryDisplays() -> (external: Int, builtin: Int, asleep: Int)? {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 0
    guard CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success else {
        return nil
    }
    var external = 0, builtin = 0, asleep = 0
    for id in ids.prefix(Int(count)) {
        if CGDisplayIsBuiltin(id) != 0 { builtin += 1 } else { external += 1 }
        if CGDisplayIsAsleep(id) != 0 { asleep += 1 }
    }
    return (external, builtin, asleep)
}

if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "--status" {
    guard let d = queryDisplays() else {
        FileHandle.standardError.write("CGGetOnlineDisplayList failed\n".data(using: .utf8)!)
        exit(2)
    }
    print("external=\(d.external) builtin=\(d.builtin) asleep=\(d.asleep)")
    exit(d.external > 0 ? 0 : 1)
}

let handlerPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
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

// launchd redirects stdout to the shared log file; without this, output
// is block-buffered and may never appear, making a live watcher look dead.
setvbuf(stdout, nil, _IONBF, 0)

var lastExternal = (queryDisplays()?.external ?? 0) > 0

NotificationCenter.default.addObserver(
    forName: NSApplication.didChangeScreenParametersNotification,
    object: nil,
    queue: .main
) { _ in
    let now = (queryDisplays()?.external ?? 0) > 0
    logLine("screen parameters changed; external: \(lastExternal) -> \(now)")
    if now != lastExternal {
        lastExternal = now
        runHandler(now ? "added" : "removed")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)   // no dock icon, no app switcher entry
logLine("started (AppKit watcher), external=\(lastExternal), handler: \(handlerPath)")
app.run()
