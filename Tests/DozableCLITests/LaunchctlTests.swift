import XCTest
@testable import DozableHost

/// 694: the login item's launchctl — the exact argv of each verb, the seam's choice, and what `print` / `print-disabled`
/// say. Nothing here runs a launchctl: the fakes are closures.
final class LaunchctlTests: XCTestCase {
    func testTheArgvOfEachVerbInThePersonsGUIDomain() {
        XCTAssertEqual(Launchctl.bootstrapArguments(plist: "/x/com.dozable.daemon.0a1b2c3d.plist", uid: 501),
                       ["bootstrap", "gui/501", "/x/com.dozable.daemon.0a1b2c3d.plist"])
        XCTAssertEqual(Launchctl.bootoutArguments(label: "com.dozable.daemon.0a1b2c3d", uid: 501), ["bootout", "gui/501/com.dozable.daemon.0a1b2c3d"])
        XCTAssertEqual(Launchctl.kickstartArguments(label: "com.dozable.daemon.0a1b2c3d", uid: 501), ["kickstart", "gui/501/com.dozable.daemon.0a1b2c3d"],
                       "no -k: a job already running is left alone")
        XCTAssertEqual(Launchctl.printArguments(label: "com.dozable.app.daemon", uid: 502), ["print", "gui/502/com.dozable.app.daemon"])
        XCTAssertEqual(Launchctl.printDisabledArguments(uid: 501), ["print-disabled", "gui/501"])
    }

    func testTheWrappersSendThoseArgv() {
        let seen = Recorded()
        let l = Launchctl(uid: 501) { argv in seen.add(argv); return .init(code: argv.first == "print" ? 113 : 0, output: "") }
        XCTAssertTrue(l.bootstrap(plist: "/a.plist").ok)
        XCTAssertTrue(l.bootout(label: "L").ok)
        XCTAssertTrue(l.kickstart(label: "L").ok)
        XCTAssertNil(l.printJob(label: "L"), "113: not loaded")
        XCTAssertEqual(seen.all, [["bootstrap", "gui/501", "/a.plist"], ["bootout", "gui/501/L"], ["kickstart", "gui/501/L"], ["print", "gui/501/L"]])
    }

    func testTheSeamIsHonouredOnlyInATestRun() {
        XCTAssertEqual(Launchctl.current(environment: ["DOZ_TEST_GUARD": "1", "DOZ_TEST_LAUNCHCTL": "/tmp/fake-lc"]).path, "/tmp/fake-lc")
        XCTAssertEqual(Launchctl.current(environment: ["DOZ_TEST_REAL_MAC": "1", "DOZ_TEST_LAUNCHCTL": "/tmp/fake-lc"]).path, "/tmp/fake-lc",
                       "a run against this Mac's login still never reaches launchd")
        // Inside XCTest every process is guarded; a person's doz (no guard) is decided by `testRun` with inXCTest false.
        XCTAssertFalse(TestSafety.testRun(["DOZ_TEST_LAUNCHCTL": "/tmp/fake-lc"], inXCTest: false), "a person's doz ignores the seam")
    }

    func testPrintDisabledBothSpellings() {
        let old = "disabled services = {\n\t\"com.apple.Siri.agent\" => disabled\n\t\"com.dozable.daemon.0a1b2c3d\" => disabled\n\t\"com.other\" => enabled\n}\n"
        XCTAssertEqual(Launchctl.parseDisabled(old, label: "com.dozable.daemon.0a1b2c3d"), true)
        XCTAssertEqual(Launchctl.parseDisabled(old, label: "com.other"), false)
        XCTAssertNil(Launchctl.parseDisabled(old, label: "com.dozable.daemon.ffffffff"), "not listed: not known")
        let new = "disabled services = {\n\t\"com.dozable.daemon.0a1b2c3d\" => true\n\t\"com.dozable.app.daemon\" => false\n}\n"
        XCTAssertEqual(Launchctl.parseDisabled(new, label: "com.dozable.daemon.0a1b2c3d"), true)
        XCTAssertEqual(Launchctl.parseDisabled(new, label: "com.dozable.app.daemon"), false)
        XCTAssertNil(Launchctl.parseDisabled(new, label: "com.dozable.daemon.0a1b"), "a prefix is not the label")
    }

    func testTheProgramOfALoadedJob() {
        let print = "gui/501/com.dozable.app.daemon = {\n\tactive count = 0\n\tpath = /x.plist\n\tprogram = /Applications/Dozable.app/Contents/MacOS/doz\n\targuments = {\n\t\t/Applications/Dozable.app/Contents/MacOS/doz\n\t\tdaemon\n\t}\n}\n"
        XCTAssertEqual(Launchctl.parseProgram(print), "/Applications/Dozable.app/Contents/MacOS/doz")
        let argsOnly = "gui/501/L = {\n\targuments = {\n\t\t/opt/homebrew/opt/doz/libexec/doz/doz\n\t\tdaemon\n\t}\n}\n"
        XCTAssertEqual(Launchctl.parseProgram(argsOnly), "/opt/homebrew/opt/doz/libexec/doz/doz")
        XCTAssertNil(Launchctl.parseProgram("gui/501/L = {\n\tstate = running\n}\n"))
    }
}

final class Recorded: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func add(_ a: [String]) { lock.withLock { calls.append(a) } }
    var all: [[String]] { lock.withLock { calls } }
}
