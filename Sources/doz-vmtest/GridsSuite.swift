import Darwin
import Foundation
import DozableKit
import DozableHost

// 648 (`make test-cli-grids`): painted thumbnails — a session's screen as cells, through the real host, in a lab
// sandbox in a store of its own (`/tmp/dzo-PID-gr`). A session prints coloured text; `session-grids` (over the host's
// status watcher — the holder announced GRID) returns its grid with those colours; the same gen answers unchanged;
// new output moves the gen; asleep, the sandbox answers
// not-running and STAYS asleep, and its saved screen carries the grid; with the host stopped every picture is
// unavailable and no host is started.

private let painter = #"""
#!/bin/sh
printf '\033[1;31mRED\033[0m \033[42mGREEN\033[0m plain\r\n'
while [ ! -e /tmp/g1 ]; do sleep 0.2; done
printf '\033[38;2;10;20;30mMORE\033[0m\r\n'
sleep 600
"""#

func cliGridsSuite(binary: String) async {
    let t = onboardingHarness(binary, "gr", seed: ["kernels", "content", "state.json", "initfs.ext4", "golden"])
    let store = DozableStore(root: t.store)
    defer {
        t.run(["host", "stop"], timeout: 300)
        try? FileManager.default.removeItem(at: t.store)
    }
    print("cli: painted thumbnails — session-grids and the saved grid (648)")
    check(t.run(["onboard", "--no-base", "--yes"], timeout: 120).code == 0, "a scratch store, onboarded")
    check(t.run(["create", "gr", "--image", "lab", "--isolated", "--memory", "512M", "--start"], timeout: 900).code == 0, "create gr --image lab --start")
    func ex(_ script: String) -> String { t.run(["exec", "gr", "--", "sh", "-c", script], timeout: 60).out }
    _ = ex("echo \(Data(painter.utf8).base64EncodedString()) | base64 -d > /tmp/painter.sh; chmod 755 /tmp/painter.sh; rm -f /tmp/g1")
    check(t.run(["run", "gr", "-d", "--session", "paint", "--", "/tmp/painter.sh"]).code == 0, "a session prints coloured text (detached)")

    func grids(_ gen: UInt32) -> SessionGridAnswer? {
        var q = HostRequest(.sessionGrids)
        q.grids = [SessionGridRequest(sandbox: "gr", session: "paint", gen: gen)]
        guard let m = try? HostClient.request(q, store: store, autostart: false), m.ok == true else { return nil }
        return (try? m.result?.decode([SessionGridAnswer].self))?.first
    }
    func run(_ g: ScreenGrid?, _ text: String) -> ScreenGrid.Run? { g?.lines.flatMap { $0 }.first { $0.text.hasPrefix(text) } }

    check(ex("deckhold ls").contains("\tgrid=1\t"), "this build's holder lists grid=1")
    var first: SessionGridAnswer?
    check(t.waitFor(20) { first = grids(0); return first?.state == .grid }, "session-grids: a grid (\(first?.state.rawValue ?? "no answer") \(first?.reason?.rawValue ?? ""))")
    let red = run(first?.grid, "RED"), green = run(first?.grid, "GREEN"), plain = run(first?.grid, "plain")
    check(red?.fg != nil && red.map { $0.flags & 1 == 1 } == true && red?.bg == nil, "RED: a red foreground, bold (\(String(describing: red)))")
    check(green?.bg != nil && green?.fg == nil, "GREEN: a green background (\(String(describing: green)))")
    check(plain?.fg == nil && plain?.bg == nil && green.map { $0.col + $0.cells } == 9 && plain?.col == 10, "plain text in the default colours, at its column")
    check(first?.grid?.cursor?.y == 1, "the cursor on the next row")
    let gen = first?.gen ?? 0
    check(gen != 0 && grids(gen)?.state == .unchanged, "the same gen: unchanged")
    _ = ex("touch /tmp/g1")
    var moved: SessionGridAnswer?
    check(t.waitFor(10) { moved = grids(gen); return moved?.state == .grid && run(moved?.grid, "MORE") != nil }, "new output moves the gen: the new grid")
    check(run(moved?.grid, "MORE")?.fg == "#0a141e", "a 24-bit colour as it is (\(run(moved?.grid, "MORE")?.fg ?? "nil"))")

    var q = HostRequest(.sessionGrids)
    q.grids = [SessionGridRequest(sandbox: "gr", session: "nope")]
    let missing = (try? HostClient.request(q, store: store, autostart: false))?.result.flatMap { try? $0.decode([SessionGridAnswer].self) }?.first
    check(missing?.state == .unavailable && missing?.reason == .noWatcher, "a session with no watcher: unavailable")

    // Asleep: not-running, and it stays asleep; the saved screen carries the grid.
    check(t.run(["sleep", "gr"], timeout: 180).code == 0, "sleep gr")
    let asleep = grids(0)
    check(asleep?.state == .unavailable && asleep?.reason == .notRunning, "asleep: unavailable, not running (\(asleep?.reason?.rawValue ?? "nil"))")
    usleep(1_000_000)
    check(t.row("gr")?.phase == "asleep", "…and it stays asleep (\(t.row("gr")?.phase ?? "nil"))")
    var sq = HostRequest(.sessionScreen, name: "gr")
    sq.session = "paint"
    let saved = (try? HostClient.request(sq, store: store, autostart: false))?.result.flatMap { try? $0.decode(SessionScreen.self) }
    check(run(saved?.grid, "RED")?.fg != nil && run(saved?.grid, "MORE") != nil, "the saved screen has its grid, in colour")
    check(FileManager.default.fileExists(atPath: store.layout("gr").screensDirectory.appendingPathComponent("paint.grid.json").path),
          "screens/paint.grid.json beside the others")

    // No host: the route's request (autostart: false) gets no answer, and no host is started by it.
    check(t.run(["host", "stop"], timeout: 300).code == 0, "doz host stop")
    check(grids(0) == nil, "no host: no answer (the route answers every item unavailable)")
    usleep(500_000)
    check(!store.hostIsRunning(), "…and no host was started")
}
