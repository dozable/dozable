import Foundation
import XCTest
import DozableTUI
@testable import DozableCLI
@testable import DozableHost

/// 637: DozableTUI — the colour decision (its precedence, the flag and the setting), every component with colour on and
/// off, and the questions driven by a scripted key stream (the same seam the typed fallback reads).
final class TUITests: XCTestCase {
    private var saved: Terminal!

    override func setUp() { saved = Terminal.current }
    override func tearDown() { Terminal.current = saved }

    // MARK: the colour decision

    func testColourPrecedenceTable() {
        // mode × tty × NO_COLOR × json/quiet → colour
        for mode in ColourMode.allCases {
            for tty in [false, true] {
                for noColor in [false, true] {
                    for suppressed in [false, true] {
                        let env = noColor ? ["NO_COLOR": ""] : [:]
                        let t = Terminal.make(colour: mode, json: suppressed, quiet: false, environment: env, stdinTTY: tty, stdoutTTY: tty)
                        let q = Terminal.make(colour: mode, json: false, quiet: suppressed, environment: env, stdinTTY: tty, stdoutTTY: tty)
                        let want: Bool = switch mode {
                        case .never: false
                        case .always: true
                        case .auto: tty && !noColor && !suppressed
                        }
                        XCTAssertEqual(t.colour, want, "\(mode) tty=\(tty) NO_COLOR=\(noColor) json=\(suppressed)")
                        XCTAssertEqual(q.colour, want, "\(mode) tty=\(tty) NO_COLOR=\(noColor) quiet=\(suppressed)")
                        XCTAssertEqual(t.interactive, tty)
                    }
                }
            }
        }
        XCTAssertFalse(Terminal.make(colour: .auto, json: false, quiet: false, environment: ["TERM": "dumb"], stdinTTY: true, stdoutTTY: true).colour,
                       "TERM=dumb turns auto off")
        XCTAssertTrue(Terminal.make(colour: .always, json: false, quiet: false, environment: ["TERM": "dumb", "NO_COLOR": "1"], stdinTTY: false, stdoutTTY: false).colour,
                      "always is always")
    }

    func testFlagEnvSettingPrecedence() throws {
        func mode(_ args: [String], env: [String: String] = [:], file: String? = nil) throws -> ColourMode {
            let g = try GlobalOptions.parse(args)
            return g.colourMode(DozableSettings(text: file, environment: env))
        }
        XCTAssertEqual(try mode([]), .auto, "the default")
        XCTAssertEqual(try mode([], file: "[ui]\ncolor = \"never\"\n"), .never, "the setting")
        XCTAssertEqual(try mode([], env: ["DOZ_COLOR": "always"], file: "[ui]\ncolor = \"never\"\n"), .always, "the environment over the setting")
        XCTAssertEqual(try mode(["--color", "auto"], env: ["DOZ_COLOR": "always"]), .auto, "the flag over the environment")
        XCTAssertEqual(try mode(["--no-color"], env: ["DOZ_COLOR": "always"], file: "[ui]\ncolor = \"always\"\n"), .never, "--no-color over everything")
        XCTAssertEqual(try mode(["--color", "never"]), .never)
        XCTAssertThrowsError(try GlobalOptions.parse(["--color", "sometimes"]))
        XCTAssertThrowsError(try GlobalOptions.parse(["--no-color", "--color", "always"]), "both, disagreeing")
        XCTAssertNoThrow(try Onboard.parse(["--no-color", "--yes"]))
        XCTAssertNoThrow(try List.parse(["--color", "never"]))
    }

    func testTheSettingIsDefinedAndDocumented() throws {
        let d = try XCTUnwrap(DozableSettings.definition(SettingKey.color))
        XCTAssertEqual(d.defaultValue, .string("auto"))
        XCTAssertEqual(d.environment, "DOZ_COLOR")
        XCTAssertNotNil(d.flag)
        guard case .choice(let c) = d.type else { return XCTFail("a choice") }
        XCTAssertEqual(c, ["auto", "always", "never"])
        let manual = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/manual/15-settings-reference.md")
        XCTAssertTrue(try String(contentsOf: manual, encoding: .utf8).contains("| `ui.color` |"), "the settings reference lists ui.color")
    }

    // MARK: components

    private func both(_ c: Component, width: Int = 60) -> (plain: String, coloured: String) {
        (c.render(width: width, colour: false), c.render(width: width, colour: true))
    }

    func testComponentsWithColourOnAndOff() {
        let parts: [(Component, [String], String)] = [
            (StepHeader(index: 2, total: 6, title: "Models & keys"), ["Step 2 of 6", "Models & keys", "─"], "\u{1B}[1;36mStep 2 of 6"),
            (Rule(), ["──────"], "\u{1B}[2m"),
            (Section("Sign-ins"), ["Sign-ins"], "\u{1B}[1mSign-ins"),
            (StatusLine(.ok, "macOS 27.0"), ["✓ macOS 27.0"], "\u{1B}[32m✓"),
            (StatusLine(.warn, "vmnet", detail: "only --network nat needs it"), ["! vmnet only --network nat needs it"], "\u{1B}[33m!"),
            (StatusLine(.bad, "disk", detail: "not APFS"), ["✕ disk not APFS"], "\u{1B}[31m✕"),
            (KeyValues([("Base", "Node.js"), ("Keys added", "none")]), ["Base        Node.js", "Keys added  none"], "\u{1B}[1mNode.js"),
            (Note("A lead that says what the step is for."), ["  A lead that says"], "\u{1B}[2m"),
            (Command("doz try claude"), ["    doz try claude"], "\u{1B}[36mdoz try claude"),
        ]
        for (c, words, sgr) in parts {
            let (plain, coloured) = both(c)
            XCTAssertFalse(plain.contains("\u{1B}"), "\(type(of: c)) with colour off has no escape: \(plain.debugDescription)")
            for w in words { XCTAssertTrue(plain.contains(w), "\(type(of: c)) plain has \(w): \(plain.debugDescription)") }
            XCTAssertTrue(coloured.contains(sgr), "\(type(of: c)) coloured has \(sgr.debugDescription): \(coloured.debugDescription)")
            XCTAssertEqual(Style.strip(coloured), plain, "\(type(of: c)): the same words either way")
        }
        XCTAssertFalse(Command("doz ui").render(width: 80, colour: true).contains("$"), "a command pastes as it is: no prompt sign")
    }

    func testWrappingAndAlignment() {
        let s = StatusLine(.warn, "vmnet", detail: String(repeating: "word ", count: 30), column: 10).render(width: 50, colour: false)
        let lines = s.components(separatedBy: "\n")
        XCTAssertGreaterThan(lines.count, 1, "a long detail wraps")
        XCTAssertTrue(lines.allSatisfy { $0.count <= 50 }, s)
        XCTAssertTrue(lines.dropFirst().allSatisfy { $0.hasPrefix(String(repeating: " ", count: 15)) }, "under the detail's column: \(s)")
        XCTAssertEqual(Layout.wrap("one two three", width: 8), ["one two", "three"])
        XCTAssertEqual(Layout.wrap("abcdefghijklmnop", width: 12, indent: "  "), ["  abcdefghij", "  klmnop"], "a long word is cut")
        XCTAssertEqual(Layout.wrap("", width: 20), [""])
    }

    func testOnboardingCheckLines() {
        let ok = OnboardingCheck(check: "macos", status: "ok", detail: "macOS 27.0", hard: true)
        let bad = OnboardingCheck(check: "disk", status: "fail", detail: "not APFS", hard: true)
        let soft = OnboardingCheck(check: "claude", status: "fail", detail: "not signed in", hard: false)
        XCTAssertEqual(OnboardingFlow.checkLine(ok, width: 80, colour: false), "  ✓ macos           macOS 27.0")
        XCTAssertTrue(OnboardingFlow.checkLine(bad, width: 80, colour: false).hasPrefix("  ✕ disk"))
        XCTAssertTrue(OnboardingFlow.checkLine(bad, width: 80, colour: false).hasSuffix("(required)"))
        XCTAssertTrue(OnboardingFlow.checkLine(soft, width: 80, colour: false).hasPrefix("  ! claude"))
        XCTAssertTrue(OnboardingFlow.checkLine(ok, width: 80, colour: true).contains("\u{1B}[32m✓"))
        XCTAssertEqual(OnboardingFlow.baseLineKind("the Node.js base is ready"), .ok)
        XCTAssertEqual(OnboardingFlow.baseLineKind("the Node.js base: step 2 of 5"), .busy)
        XCTAssertEqual(OnboardingFlow.baseLineKind("the Node.js base: failed — x (a tool's first start prepares it again)"), .warn)
    }

    // MARK: the questions, by key

    private let down = "\u{1B}[B", up = "\u{1B}[A"

    private func keys(_ input: String, colour: Bool = false) -> (Prompter, ScriptedChannel) {
        let ch = ScriptedChannel(input)
        var p = Prompter(channel: ch, keys: true, colour: colour, width: 70)
        p.onInterrupt = {}
        return (p, ch)
    }

    func testChoiceByArrowsNumbersAndDefault() {
        let opts = ["Off — not signed in as you", "Read-only — clone and read", "Read and push — also push"]
        var (p, ch) = keys("\r")
        XCTAssertEqual(p.choose("  GitHub as you?", opts, preferred: 1), 1, "Enter keeps the default")
        XCTAssertTrue(ch.output.contains("(recommended)"), "the default is marked")
        XCTAssertTrue(ch.output.contains("not signed in as you"), "each option's detail is shown")
        XCTAssertTrue(ch.output.contains("✓ Read-only"), "the answer stays on screen")
        (p, ch) = keys(down + down + "\r")
        XCTAssertEqual(p.choose("  GitHub as you?", opts, preferred: 0), 2, "↓↓ Enter")
        (p, ch) = keys(down + down + down + "\r")
        XCTAssertEqual(p.choose("Q", opts, preferred: 0), 0, "↓ past the last wraps to the first")
        (p, ch) = keys(up + "\r")
        XCTAssertEqual(p.choose("Q", opts, preferred: 0), 2, "↑ from the first wraps to the last")
        (p, ch) = keys("jjk\r")
        XCTAssertEqual(p.choose("Q", opts, preferred: 0), 1, "j/k move too")
        (p, ch) = keys("3")
        XCTAssertEqual(p.choose("Q", opts, preferred: 0), 2, "a number picks at once")
        XCTAssertEqual(ch.remaining, 0)
        let twelve = (1...12).map { "option \($0)" }
        (p, ch) = keys("1\r")
        XCTAssertEqual(p.choose("Q", twelve, preferred: 5), 0, "1 of 12 could start 10–12: it waits for Enter")
        (p, ch) = keys("12")
        XCTAssertEqual(p.choose("Q", twelve, preferred: 0), 11, "12")
        (p, ch) = keys("")
        XCTAssertEqual(p.choose("Q", opts, preferred: 2), 2, "the end of input: the default")
        XCTAssertFalse(ch.output.contains("\u{1B}[3"), "no colour asked for: no colour")
        (p, ch) = keys(down + "\r", colour: true)
        _ = p.choose("Q", opts, preferred: 0)
        XCTAssertTrue(ch.output.contains("\u{1B}[36m❯"), "colour on: the cursor is in the accent")
    }

    func testChoiceRedrawsInPlace() {
        let (p, ch) = keys(down + "\r")
        _ = p.choice("Q", [ChoiceOption("A", detail: "a"), ChoiceOption("B")], default: 0)
        // Block: A, its detail, B, the hint = 4 lines; the redraw goes up 3 and erases.
        XCTAssertTrue(ch.output.contains("\u{1B}[3A\r\u{1B}[J"), ch.output.debugDescription)
        XCTAssertTrue(ch.output.hasSuffix("\u{1B}[?25h"), "the cursor is shown again")
    }

    /// 637 (owner: a choice taller than the window redrew itself too far up): a live block never has more rows than the
    /// window allows — the options are windowed around the selection, with "↑/↓ N more", and a redraw goes up at most
    /// that many rows.
    func testATallChoiceFitsTheWindow() {
        let opts = (1...11).map { ChoiceOption("Base \($0)", detail: "what base \($0) is") }    // 23 rows in full
        let ch = ScriptedChannel(String(repeating: down, count: 10) + "\r")
        var p = Prompter(channel: ch, keys: true, width: 70, height: 14)
        p.onInterrupt = {}
        XCTAssertEqual(p.choice("Which base image?", opts, default: 0), 10, "↓ ×10 reaches the last")
        let ups = ch.output.components(separatedBy: "\u{1B}[").compactMap { s -> Int? in
            guard let a = s.firstIndex(of: "A"), let n = Int(s[..<a]) else { return nil }
            return n
        }
        XCTAssertFalse(ups.isEmpty)
        XCTAssertTrue(ups.allSatisfy { $0 <= 14 - 3 - 1 }, "never up past the block's own rows: \(ups)")
        XCTAssertTrue(ch.output.contains("↓ 10 more") || ch.output.contains("↓ "), "hidden options are said")
        XCTAssertTrue(ch.output.contains("↑ "), "and those scrolled past above")
        XCTAssertTrue(ch.output.contains("❯ \("11.") Base 11") || ch.output.contains("Base 11"), "the selection stays in view")
        // A short list in a tall window is drawn whole, with no "more" lines.
        let (q, sh) = keys("\r")
        _ = q.choice("Q", [ChoiceOption("A"), ChoiceOption("B")], default: 0)
        XCTAssertFalse(sh.output.contains("more"))
    }

    /// 637 (owner: a pause after the checks and before the first sandbox): with keys it waits for Enter (other keys do
    /// nothing); typed answers never wait — no scripted run needs an extra line.
    func testPauseWaitsForEnterOnlyWithKeys() {
        let (p, ch) = keys("x \r")
        p.pause("  ", "continue")
        XCTAssertEqual(ch.remaining, 0, "x and space are ignored; Enter goes on")
        XCTAssertTrue(ch.output.contains("Press Enter to continue"))
        let typed = ScriptedChannel("2\n", keys: true)
        let q = Prompter(channel: typed, keys: false, width: 70)
        q.pause("  ", "continue")
        XCTAssertEqual(typed.remaining, 2, "typed answers: nothing read")
    }

    func testInterruptRestoresAndStops() {
        let ch = ScriptedChannel("\u{03}")
        var p = Prompter(channel: ch, keys: true, width: 70)
        var interrupted = false
        p.onInterrupt = { interrupted = true }
        XCTAssertEqual(p.choose("Q", ["a", "b"], preferred: 1), 1)
        XCTAssertTrue(interrupted, "Ctrl-C goes to the interrupt (the terminal restored first)")
    }

    func testYesNo() {
        var (p, ch) = keys("y")
        XCTAssertTrue(p.yesNo("Sign up?", default: false))
        (p, ch) = keys("n")
        XCTAssertFalse(p.yesNo("Sign up?", default: true))
        (p, ch) = keys("\r")
        XCTAssertTrue(p.yesNo("Sign up?", default: true), "Enter keeps the default")
        (p, ch) = keys(down + "\r")
        XCTAssertFalse(p.yesNo("Sign up?", default: true), "an arrow moves to the other answer")
        XCTAssertTrue(ch.output.contains("No"))
    }

    func testTextFieldDefaultTypedAndInlineValidation() {
        let rule: (String) -> String? = { $0.contains(" ") || $0.lowercased() != $0 ? "1–40 of a-z 0-9 -" : nil }
        var (p, ch) = keys("\r")
        XCTAssertEqual(p.text("  Name", default: "claude", valid: rule), "claude", "Enter takes the default")
        XCTAssertTrue(ch.output.contains("claude"), "the default is shown")
        (p, ch) = keys("my-box\r")
        XCTAssertEqual(p.text("  Name", default: "claude", valid: rule), "my-box")
        (p, ch) = keys("Bad Name\r" + String(repeating: "\u{7F}", count: 8) + "good\r")
        XCTAssertEqual(p.text("  Name", default: "claude", valid: rule), "good", "refused, then asked again in place")
        XCTAssertTrue(ch.output.contains("✕ 1–40 of a-z 0-9 -"), "the reason, under the field: \(ch.output.debugDescription)")
        (p, ch) = keys("ab\u{15}cd\r")
        XCTAssertEqual(p.text("Q", default: "x"), "cd", "Ctrl-U clears the line")
        (p, ch) = keys("\tz\r")
        XCTAssertEqual(p.text("Q", default: "dflt"), "dfltz", "Tab takes the default to edit")
        (p, ch) = keys("café\r")
        XCTAssertEqual(p.text("Q", default: ""), "café", "UTF-8 typed")
    }

    func testChecklistToggles() {
        let items: [(label: String, ticked: Bool)] = [("News", false), ("Early access", true), ("Tips", false)]
        var (p, _) = keys("\r")
        XCTAssertEqual(p.checklist("What would you like?", items), [false, true, false], "Enter keeps the ticks")
        (p, _) = keys(" " + down + " " + down + " \r")
        XCTAssertEqual(p.checklist("What would you like?", items), [true, false, true], "Space toggles under the cursor")
        (p, _) = keys("3\r")
        XCTAssertEqual(p.checklist("Q", items), [false, true, true], "a number toggles that item")
    }

    // MARK: the typed fallback (the reference: exactly as before)

    func testTypedFallback() {
        let ch = ScriptedChannel("2\nfoo\n\nn\n1,3\nother\n", keys: true)
        let p = Prompter(channel: ch, keys: false, width: 70)
        XCTAssertEqual(p.choose("Network", ["agent — proxied", "bake — registries"], preferred: 0), 1)
        XCTAssertTrue(ch.output.contains("  1) agent — proxied   ← recommended\n  2) bake — registries\nChoose 1–2 [1]: "), ch.output)
        XCTAssertEqual(p.text("Name", default: "x"), "foo")
        XCTAssertEqual(p.text("Name", default: "x"), "x", "Enter keeps the default")
        XCTAssertFalse(p.yesNo("Go?", default: true))
        XCTAssertEqual(p.checklist("Q", [("a", false), ("b", false), ("c", false)]), [true, false, true])
        XCTAssertEqual(p.pick("Use it?", ["y", "n", "other"], default: "y"), "other")
        XCTAssertFalse(ch.output.contains("\u{1B}"), "typed answers: no escape sequences")
    }

    func testKeysRefusedFallsBackToTyped() {
        let ch = ScriptedChannel("2\n", keys: false)
        let p = Prompter(channel: ch, keys: true, width: 70)
        XCTAssertEqual(p.choose("Q", ["a", "b"], preferred: 0), 1, "no raw mode to be had: typed, as before")
        XCTAssertTrue(ch.output.contains("Choose 1–2 [1]: "))
    }

    func testNotInteractiveTakesDefaults() {
        let p = Prompter(yes: true, json: false, keys: true)
        XCTAssertFalse(p.interactive)
        XCTAssertEqual(p.choose("Q", ["a", "b"], preferred: 1), 1)
        XCTAssertEqual(p.text("Q", default: "d"), "d")
        XCTAssertTrue(p.yesNo("Q", default: true))
    }
}
