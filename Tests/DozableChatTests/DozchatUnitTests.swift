import Darwin
@testable import DozableChat
import Foundation
import XCTest

/// dozchat's C parts (Guest/dozchat/dozchat.c) from `make test`: the unit check (Guest/dozchat/test/unit-check.c) compiled
/// here with the Mac's /usr/bin/cc under AddressSanitizer and UndefinedBehaviorSanitizer (nothing recovers) and run with
/// at least 20,000 fuzz iterations; the escaper's output decoded by JSONSerialization for 10,000 random strings; and the
/// name vectors it shares with the chat server, checked against the server's own `ChatFileRules.cleanName`.
final class DozchatUnitTests: XCTestCase {
    static var guest: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Guest/dozchat")
    }
    static let cc = "/usr/bin/cc"
    var root: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: Self.cc) else {
            throw NSError(domain: "DozchatUnitTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(Self.cc) is missing (xcode-select --install)"])
        }
        root = URL(fileURLWithPath: "/tmp").appendingPathComponent("dzcu-\(getpid())-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    struct Run { let code: Int32; let out: String; let err: String }

    func run(_ exe: String, _ args: [String], env: [String: String] = ["PATH": "/usr/bin:/bin"]) throws -> Run {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = env
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        try p.run()
        var out = Data(), err = Data()
        let g = DispatchGroup()
        g.enter(); DispatchQueue.global().async { out = o.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); DispatchQueue.global().async { err = e.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        p.waitUntilExit()
        g.wait()
        return Run(code: p.terminationStatus, out: String(decoding: out, as: UTF8.self), err: String(decoding: err, as: UTF8.self))
    }

    func buildCheck() throws -> String {
        let exe = root.appendingPathComponent("unit-check").path
        let r = try run(Self.cc, ["-O1", "-g", "-std=c11", "-Wall", "-Wextra", "-Wformat=2", "-Wshadow", "-Wvla", "-Werror", "-Wno-unused-function",
                                  "-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-fno-omit-frame-pointer",
                                  Self.guest.appendingPathComponent("test/unit-check.c").path, "-o", exe])
        XCTAssertEqual(r.code, 0, "the unit check compiles without a warning: \(r.err)")
        return exe
    }

    func testTheUnitCheckPassesUnderTheSanitizers() throws {
        let exe = try buildCheck()
        let r = try run(exe, ["--vectors", Self.guest.appendingPathComponent("test/clean-name.tsv").path, "--iterations", "20000", "--seed", "710"],
                        env: ["PATH": "/usr/bin:/bin", "ASAN_OPTIONS": "detect_leaks=0", "UBSAN_OPTIONS": "halt_on_error=1"])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.contains("ok dozchat-check:") && r.out.contains("20000 fuzz iterations"), r.out + r.err)
    }

    func testTheEscaperAgreesWithJSONSerialization() throws {
        let exe = try buildCheck()
        var rng = SystemRandomNumberGenerator()
        var strings: [String] = []
        let pool: [Unicode.Scalar] = ["a", "\"", "\\", "/", "\n", "\r", "\t", "\u{0}", "\u{1f}", "\u{7f}", "\u{80}", "é", "€", "\u{2028}",
                                      "\u{fffd}", "\u{ffff}", "😀", "\u{10ffff}", "<", " "]
        for _ in 0..<10_000 {
            var s = String.UnicodeScalarView()
            for _ in 0..<Int.random(in: 0...24, using: &rng) {
                if Bool.random(using: &rng) { s.append(pool.randomElement(using: &rng)!) } else {
                    var v = UInt32.random(in: 0...0x10FFFF, using: &rng)
                    if (0xD800...0xDFFF).contains(v) { v = 0x41 }
                    s.append(Unicode.Scalar(v)!)
                }
            }
            strings.append(String(s))
        }
        let file = root.appendingPathComponent("strings.hex")
        try Data(strings.map { Array($0.utf8).map { String(format: "%02x", $0) }.joined() }.joined(separator: "\n").utf8 + [10]).write(to: file)
        let r = try run(exe, ["escape", file.path], env: ["PATH": "/usr/bin:/bin", "ASAN_OPTIONS": "detect_leaks=0"])
        XCTAssertEqual(r.code, 0, r.err)
        let lines = r.out.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
        XCTAssertEqual(lines.count, strings.count)
        var wrong = 0
        for (s, line) in zip(strings, lines) {
            let back = try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed]) as? String
            if back != s { wrong += 1 }
            if line.utf8.contains(where: { $0 < 0x20 || $0 == 0x7f }) { wrong += 1 }
        }
        XCTAssertEqual(wrong, 0, "every escaped string decodes back to itself and holds no raw control byte")
    }

    func testTheNameVectorsAreTheServersRule() throws {
        let text = try String(contentsOf: Self.guest.appendingPathComponent("test/clean-name.tsv"), encoding: .utf8)
        var n = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where !line.hasPrefix("#") && !line.isEmpty {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(parts.count, 2, "a vector line: \(line)")
            guard parts.count == 2 else { continue }
            XCTAssertEqual(ChatFileRules.cleanName(parts[0]), parts[1], "cleanName(\(parts[0].debugDescription))")
            n += 1
        }
        XCTAssertGreaterThanOrEqual(n, 20)
    }

    /// The Python client (docs/chat/client/chat_client.py) names a file the server's way too.
    func testThePythonClientFollowsTheSameNameRule() throws {
        let client = Self.guest.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("docs/chat/client/chat_client.py").path
        let script = """
            import importlib.util, sys
            spec = importlib.util.spec_from_file_location("c", sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
            bad = [l for l in open(sys.argv[2], encoding="utf-8").read().split("\\n") if l and not l.startswith("#") and m.clean_name(l.split("\\t")[0]) != l.split("\\t")[1]]
            print(len(bad)); print(bad[:3])
            """
        let r = try run("/usr/bin/python3", ["-I", "-c", script, client, Self.guest.appendingPathComponent("test/clean-name.tsv").path])
        XCTAssertEqual(r.code, 0, r.err)
        XCTAssertTrue(r.out.hasPrefix("0\n"), r.out)
    }
}
