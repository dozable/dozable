import Foundation
import XCTest
@testable import DozableHost
@testable import DozableKit

/// 666: Open signs the Mac's browser in — a recipe's `ports@1 sign_in` (OpenCode 2: `opencode pair`). The link it prints
/// is found (only a link to the port, on a loopback host), opened at the Mac's port, and the token goes NOWHERE else:
/// not the answer, the line said to viewers and the host log, a failure's words, or the opener seam's record.
final class PortSignInTests: XCTestCase {
    /// A fake token of OpenCode's shape (22 characters of base64url).
    static let token = "Zq3vT9kLmN0pQrStUvWxY_"
    /// OpenCode 2's own output (2.0.29 and 2.1.4 print the same — the workspace's probes/666-*), the token replaced.
    static var pairStdout: String { "\n  Open a link to connect. Links work once and expire in 5 minutes.\n\n  http://127.0.0.1:49374/auth/connect/\(token)\n\n" }
    static let pairStderr = """
          Over SSH? Forward the port, then open the link on your machine:
          ssh -L 49374:127.0.0.1:49374 <host>
          If port 49374 is busy locally, forward another port and use it in the link.

          To connect from other devices, run `opencode service set hostname 0.0.0.0`.

        """
    static let pair = AgentRecipe.SignIn(argv: ["opencode", "pair"], linkPath: "/auth/connect/")

    func testTheLinkIsOpenCodesPairLink() {
        let out = Self.pairStdout + "\n" + Self.pairStderr
        XCTAssertEqual(PortSignIn.link(in: out, guestPort: 49374, linkPath: "/auth/connect/"), "/auth/connect/\(Self.token)")
        XCTAssertEqual(PortSignIn.link(in: out, guestPort: 49374, linkPath: nil), "/auth/connect/\(Self.token)")
        XCTAssertNil(PortSignIn.link(in: Self.pairStderr, guestPort: 49374, linkPath: nil), "the hints print no link")
    }

    func testOnlyALinkToThisPortOnALoopbackHostIsTaken() {
        func link(_ s: String, _ port: Int, _ prefix: String? = nil) -> String? { PortSignIn.link(in: s, guestPort: port, linkPath: prefix) }
        let text = "docs: https://opencode.ai/docs/pair\nanother port: http://127.0.0.1:3000/x?token=a\nhere: http://localhost:8888/lab?token=abc.\n"
        XCTAssertEqual(link(text, 8888), "/lab?token=abc", "the first link to the port; the sentence's full stop is not the link's")
        XCTAssertNil(link(text, 9999), "no link to this port")
        XCTAssertNil(link("http://evil.example:8888/x", 8888), "never a host other than a loopback one")
        XCTAssertNil(link("http://user:pw@127.0.0.1:8888/x", 8888), "never a link with a login in it")
        XCTAssertEqual(link("see http://127.0.0.1/a", 80), "/a", "no port = the scheme's")
        XCTAssertEqual(link("\u{1B}[1;32mhttp://127.0.0.1:8888/a?t=1#f\u{1B}[0m", 8888), "/a?t=1#f", "colour out; query and fragment kept")
        XCTAssertEqual(link("\u{1B}]8;;http://127.0.0.1:8888/a\u{07}open\u{1B}]8;;\u{07} http://127.0.0.1:8888/b", 8888), "/b",
                       "a hyperlink escape is not text a person sees")
        XCTAssertNil(link("http://127.0.0.1:8888/other", 8888, "/auth/"), "link_path narrows it")
        XCTAssertEqual(link("http://[::1]:8888/z", 8888), "/z")
        XCTAssertEqual(link("http://0.0.0.0:8888", 8888), "/")
        XCTAssertNil(link("", 8888))
    }

    func testWhatMayBeShownOfASignInURL() {
        let u = URL(string: "http://127.0.0.1:50001/auth/connect/\(Self.token)?x=1#y")!
        XCTAssertEqual(PortSignIn.shown(u), "http://127.0.0.1:50001/auth/connect/…?…#…")
        XCTAssertEqual(PortSignIn.shown(URL(string: "http://127.0.0.1:8888/?token=\(Self.token)")!), "http://127.0.0.1:8888/?…")
    }

    /// What a run touched: the argv run, the URLs opened, and every string it produced.
    final class Seen: @unchecked Sendable {
        var ran: [[String]] = []
        var seconds: [Int] = []
        var opened: [(url: String, signedIn: Bool)] = []
    }

    func run(_ exec: @escaping ([String]) throws -> ExecResult, openOK: @escaping (Bool) -> Bool = { _ in true },
             s: AgentRecipe.SignIn = PortSignInTests.pair) async -> (PortSignIn.Outcome, Seen) {
        let seen = Seen()
        let o = await PortSignIn.run(s, title: "OpenCode web", guestPort: 49374, macPort: 50001, path: "/",
                                     exec: { argv, secs in seen.ran.append(argv); seen.seconds.append(secs); return try exec(argv) },
                                     open: { url, signedIn in seen.opened.append((url.absoluteString, signedIn)); return openOK(signedIn) })
        return (o, seen)
    }

    /// Every string a run may hand on — the answer as the host sends it, and the line for viewers and the host log.
    func assertTheTokenIsNowhere(_ o: PortSignIn.Outcome, _ file: StaticString = #filePath, _ line: UInt = #line) throws {
        let answer = PortOpened(sandbox: "oc", port: 49374, title: "OpenCode web", url: o.url, signedIn: o.signedIn, problem: o.problem)
        let wire = String(decoding: try HostWire.encoder.encode(answer), as: UTF8.self)
        let event = HostEvent(kind: .note, sandbox: "oc", text: o.line)
        for s in [wire, o.line, o.problem ?? "", o.url, event.line, String(decoding: try HostWire.encoder.encode(event), as: UTF8.self)] {
            XCTAssertFalse(s.contains(Self.token), "the token in \(s)", file: file, line: line)
            XCTAssertFalse(s.contains("auth/connect"), "the link's path in \(s)", file: file, line: line)
        }
    }

    func testASignInOpensTheLinkAtTheMacsPortAndTheTokenGoesNowhereElse() async throws {
        let (o, seen) = await run { _ in ExecResult(exitCode: 0, stdout: Data(Self.pairStdout.utf8), stderr: Data(Self.pairStderr.utf8)) }
        XCTAssertEqual(seen.ran, [["opencode", "pair"]], "the recipe's argv — never a shell")
        XCTAssertEqual(seen.seconds, [15], "the default limit")
        XCTAssertEqual(seen.opened.count, 1)
        XCTAssertEqual(seen.opened.first?.url, "http://127.0.0.1:50001/auth/connect/\(Self.token)",
                       "the link's path at the Mac's port (it printed 49374; the forward is 50001 here)")
        XCTAssertEqual(seen.opened.first?.signedIn, true)
        XCTAssertTrue(o.signedIn && o.opened)
        XCTAssertNil(o.problem)
        XCTAssertEqual(o.url, "http://127.0.0.1:50001/", "the answer's URL is the plain one")
        XCTAssertEqual(o.line, "OpenCode web: opened on this Mac, signed in with a one-time link from `opencode pair`")
        try assertTheTokenIsNowhere(o)
    }

    /// Each failure says what went wrong in the recipe's words, opens the page as it is — and never repeats what the
    /// command printed (here the token is in every output and in the error's own text).
    func testAFailedSignInSaysWhyOpensThePlainPageAndNeverEchoesTheOutput() async throws {
        let leaky = Data("http://127.0.0.1:49374/auth/connect/\(Self.token)\n".utf8)
        let cases: [(String, ([String]) throws -> ExecResult, String)] = [
            ("exit 1", { _ in ExecResult(exitCode: 1, stdout: leaky, stderr: leaky) }, "`opencode pair` exited with 1"),
            ("another port only", { _ in ExecResult(exitCode: 0, stdout: Data("http://127.0.0.1:4096/auth/connect/\(Self.token)".utf8), stderr: Data()) },
             "`opencode pair` printed no link to port 49374"),
            ("its error carries the output", { _ in throw SandboxError.commandFailed(command: "opencode pair", exitCode: 2, output: String(decoding: leaky, as: UTF8.self)) },
             "`opencode pair` could not be run in the sandbox"),
            ("too slow", { _ in throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "timeout waiting for process \(Self.token)"]) },
             "`opencode pair` did not finish within 15 s"),
            ("not installed", { _ in throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "failed to find target executable opencode"]) },
             "`opencode` is not installed in this sandbox"),
        ]
        for (what, exec, problem) in cases {
            let (o, seen) = await run(exec)
            XCTAssertFalse(o.signedIn, what)
            XCTAssertEqual(o.problem, problem, what)
            XCTAssertEqual(seen.opened.map { $0.url }, ["http://127.0.0.1:50001/"], "\(what): the plain page, and only it")
            XCTAssertEqual(seen.opened.map { $0.signedIn }, [false], what)
            XCTAssertEqual(o.line, "OpenCode web: could not sign in — \(problem); opened http://127.0.0.1:50001/ without signing in", what)
            try assertTheTokenIsNowhere(o)
        }
        // The Mac would not open the link: the plain page instead, said.
        let (o, seen) = await run({ _ in ExecResult(exitCode: 0, stdout: Data(Self.pairStdout.utf8), stderr: Data()) }, openOK: { !$0 })
        XCTAssertEqual(o.problem, "this Mac could not open the sign-in link")
        XCTAssertEqual(seen.opened.map { $0.signedIn }, [true, false])
        try assertTheTokenIsNowhere(o)
        // Nothing opens at all: said, and not "opened".
        let (none, _) = await run({ _ in ExecResult(exitCode: 1, stdout: Data(), stderr: Data()) }, openOK: { _ in false })
        XCTAssertFalse(none.opened)
        XCTAssertTrue(none.line.hasSuffix("this Mac could not open http://127.0.0.1:50001/ either"), none.line)
        // A recipe's own shorter limit is the one used.
        let (_, slow) = await run({ _ in ExecResult(exitCode: 0, stdout: Data(), stderr: Data()) },
                                  s: AgentRecipe.SignIn(argv: ["opencode", "pair"], timeout: 5))
        XCTAssertEqual(slow.seconds, [5])
    }

    /// The opener seam plays the browser: it records the sign-in without its secret part, GETs the link with the
    /// browser's Accept, keeps the cookies in memory, follows the redirect, checks a signed-in page — and writes status
    /// codes and cookie NAMES only. A fake OpenCode web behind a real forward on this Mac's loopback.
    func testTheOpenerSeamSignsInLikeABrowserAndRecordsNoSecret() throws {
        let session = "SESSION-VALUE-\(UUID().uuidString)"
        final class Spent: @unchecked Sendable { let lock = NSLock(); var spent = false }
        let link = Spent()
        let f = try StandingForward(sandbox: "oc", guestPort: 49374, candidates: [0], openStream: {
            GuestStream.inMemory { req in
                let head = String(decoding: req, as: UTF8.self)
                let line = head.split(separator: "\r\n").first.map(String.init) ?? ""
                let hasCookie = head.contains("opencode_session_49374=\(session)")
                func answer(_ status: String, _ extra: String = "") -> Data { Data("HTTP/1.1 \(status)\r\n\(extra)Content-Length: 0\r\n\r\n".utf8) }
                if line.hasPrefix("GET /auth/connect/\(PortSignInTests.token) ") {
                    let first: Bool = link.lock.withLock { let f = !link.spent; link.spent = true; return f }
                    return first ? answer("302 Found", "Location: /\r\nSet-Cookie: opencode_session_49374=\(session); Path=/; HttpOnly\r\n") : answer("401 Unauthorized")
                }
                if line.hasPrefix("GET / ") { return answer("200 OK") }
                if line.hasPrefix("GET /api/session ") { return answer(hasCookie ? "200 OK" : "401 Unauthorized") }
                return answer("404 Not Found")
            }
        })
        f.start()
        defer { f.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("doz-666-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let seam = dir.appendingPathComponent("opened").path
        let url = URL(string: "http://127.0.0.1:\(f.macPort)/auth/connect/\(Self.token)")!
        XCTAssertTrue(PortSignIn.openOnMac(url, signedIn: true, environment: ["DOZ_TEST_OPEN_URL": seam, "DOZ_TEST_SIGNED_IN_CHECK": "/api/session"]))
        var text = ""
        for _ in 0..<50 where !text.contains("signed-in-browser") {
            Thread.sleep(forTimeInterval: 0.1)
            text = (try? String(contentsOfFile: seam, encoding: .utf8)) ?? ""
        }
        XCTAssertTrue(text.contains("open-signed-in http://127.0.0.1:\(f.macPort)/auth/connect/…\n"), text)
        XCTAssertTrue(text.contains("signed-in-browser link 302 cookies opencode_session_49374 · then / 200 · /api/session 200 · without the cookies 401 · the link again 401"), text)
        XCTAssertFalse(text.contains(Self.token), "the seam never writes the link's secret")
        XCTAssertFalse(text.contains(session), "…nor a cookie's value")
        // A plain open is recorded as it is (no sign-in in it).
        XCTAssertTrue(PortSignIn.openOnMac(URL(string: "http://127.0.0.1:\(f.macPort)/")!, signedIn: false, environment: ["DOZ_TEST_OPEN_URL": seam]))
        XCTAssertTrue(((try? String(contentsOfFile: seam, encoding: .utf8)) ?? "").contains("open http://127.0.0.1:\(f.macPort)/\n"))
    }

    // MARK: the recipe format

    func testOpenCode2DeclaresItsSignIn() throws {
        let p = try XCTUnwrap(AgentRecipes.recipe("opencode2")?.ports?.ports.first)
        XCTAssertEqual(p.port, 49374)
        XCTAssertEqual(p.signIn, AgentRecipe.SignIn(argv: ["opencode", "pair"], linkPath: "/auth/connect/"))
        XCTAssertEqual(p.signIn?.seconds, 15)
        XCTAssertEqual(p.auth, "token", "the hint stays: the way by hand")
        // The row says Open signs in (the command, never its output); a port without one says nothing.
        XCTAssertNil(AgentRecipes.recipe("aichat")?.ports?.ports.first?.signIn)
    }

    func testASignInIsTheRecipesOwnProgramNeverAShell() throws {
        guard var r = AgentRecipes.recipe("opencode2"), let base = r.ports else { return XCTFail("opencode2") }
        XCTAssertNoThrow(try r.validate())
        func with(_ s: AgentRecipe.SignIn, auth: String? = "token", protocol proto: String? = nil) -> AgentRecipe.WebPorts {
            var w = base
            w.ports[0].signIn = s
            w.ports[0].auth = auth
            w.ports[0].protocol = proto
            return w
        }
        func bad(_ w: AgentRecipe.WebPorts, _ why: String) {
            r.ports = w
            XCTAssertThrowsError(try r.validate(), why)
        }
        func good(_ w: AgentRecipe.WebPorts, _ why: String) {
            r.ports = w
            XCTAssertNoThrow(try r.validate(), why)
        }
        good(with(.init(argv: ["opencode", "pair"])), "no link_path: the first link to the port")
        good(with(.init(argv: ["opencode", "pair"], linkPath: "/auth/", timeout: 1)), "a short limit")
        bad(with(.init(argv: ["sh", "-c", "opencode pair"])), "a shell")
        bad(with(.init(argv: ["bash", "-lc", "opencode pair"])), "a shell")
        bad(with(.init(argv: ["env", "opencode", "pair"])), "another program first")
        bad(with(.init(argv: ["/bin/sh"])), "a path to a shell")
        bad(with(.init(argv: [])), "nothing to run")
        bad(with(.init(argv: ["opencode", ""])), "an empty word")
        bad(with(.init(argv: ["opencode", "pa\nir"])), "a control character")
        bad(with(.init(argv: Array(repeating: "opencode", count: 9))), "too many words")
        bad(with(.init(argv: ["opencode", "pair"], timeout: 0)), "no time")
        bad(with(.init(argv: ["opencode", "pair"], timeout: 60)), "too long")
        bad(with(.init(argv: ["opencode", "pair"], linkPath: "auth")), "a link_path that is not a path")
        bad(with(.init(argv: ["opencode", "pair"]), auth: "none"), "only where the port asks for a token")
        bad(with(.init(argv: ["opencode", "pair"]), protocol: "ws"), "only on an http port")
    }

    func testTheWireShapes() throws {
        var row = PortForwardRow(port: 49374, title: "OpenCode web", path: "/", protocol: "http", origin: "recipe", state: "listening",
                                 macPort: 49374, url: "http://127.0.0.1:49374/", auth: "token", tokenHint: "by hand: opencode pair")
        row.signIn = "opencode pair"
        let json = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        XCTAssertTrue(json.contains("\"sign_in\":\"opencode pair\""), json)
        var r = HostRequest(.portOpen, name: "oc")
        r.openPort = 49374
        let back = try HostWire.decoder.decode(HostRequest.self, from: try HostWire.encoder.encode(r))
        XCTAssertEqual(back.op, .portOpen)
        XCTAssertEqual(back.openPort, 49374)
        XCTAssertEqual(HostOp.portOpen.rawValue, "port-open")
        XCTAssertFalse(HostOp.portOpen.isReadOnly, "the forwards live in the host")
        XCTAssertFalse(HostOp.portOpen.isAnsweredWithoutHost)
        let o = PortOpened(sandbox: "oc", port: 49374, title: "OpenCode web", url: "http://127.0.0.1:49374/", signedIn: true)
        let oj = String(decoding: try JSONEncoder().encode(o), as: UTF8.self)
        XCTAssertTrue(oj.contains("\"signed_in\":true"), oj)
        XCTAssertEqual(try JSONDecoder().decode(PortOpened.self, from: Data(oj.utf8)), o)
    }
}
