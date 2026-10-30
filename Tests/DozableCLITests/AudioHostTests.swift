import Foundation
import DozableKit
import XCTest
@testable import DozableHost

/// 604 → 667 — sound in the host: `--audio` reaches the spec (and only it), the sound kernel is never taken
/// unverified, and the host can name the app macOS asks about the microphone for. 667: the per-sandbox setting, the
/// microphone's decision (seamed — no test ever reaches macOS's real permission) and the create's resolution.
final class AudioHostTests: XCTestCase {
    var root: URL!
    var store: DozableStore { DozableStore(root: root.appendingPathComponent("store")) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("audiohost-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("store"), withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func testAudioReachesTheSpecAndNothingElseChanges() throws {
        let (plain, _) = try DozableImages.spec(name: "p1", options: CreateOptions(image: "lab"), store: store, environment: [:])
        var o = CreateOptions(image: "lab")
        o.audio = true
        let (audio, _) = try DozableImages.spec(name: "p1", options: o, store: store, environment: [:])
        XCTAssertNil(plain.audio)
        XCTAssertEqual(audio.audio, true)
        var same = audio
        same.audio = nil
        XCTAssertEqual(same, plain, "audio is the only difference (the kernel path stays the pinned one's)")
        XCTAssertNil(audio.kernelPath)
        // An options JSON without the field decodes as before.
        let old = try JSONDecoder().decode(CreateOptions.self, from: Data(#"{"image":"lab"}"#.utf8))
        XCTAssertNil(old.audio)
    }

    func testTheSoundKernelIsRefusedWhenThisDozCarriesNone() throws {
        let cache = root.appendingPathComponent("kernels")
        XCTAssertThrowsError(try MacAudio.installSoundKernel(into: cache, environment: [:])) { e in
            XCTAssertTrue(HostError.from(e).message.contains("does not carry"), HostError.from(e).message)
        }
        let fake = root.appendingPathComponent("fake-kernel")
        try Data(repeating: 1, count: 1024).write(to: fake)
        XCTAssertThrowsError(try MacAudio.installSoundKernel(into: cache, environment: ["DOZ_TEST_SOUND_KERNEL": fake.path])) { e in
            XCTAssertTrue(HostError.from(e).message.contains("not the pinned file"), HostError.from(e).message)
        }
    }

    // MARK: 667 — the setting, the microphone

    func testTheSoundModeAtCreateAndAfter() {
        let off = TOMLValue.string("off"), speakers = TOMLValue.string("speakers"), on = TOMLValue.string("on")
        // The flag wins, then the sandbox's own value, then the setting.
        XCTAssertEqual(SoundMode.atCreate(flag: .on, own: speakers, setting: off), .on)
        XCTAssertEqual(SoundMode.atCreate(flag: nil, own: speakers, setting: on), .speakers)
        XCTAssertEqual(SoundMode.atCreate(flag: nil, own: off, setting: on), .off)
        XCTAssertEqual(SoundMode.atCreate(flag: nil, own: nil, setting: on), .on)
        XCTAssertEqual(SoundMode.atCreate(flag: nil, own: nil, setting: off), .off)
        XCTAssertEqual(SoundMode.atCreate(flag: nil, own: .string("loud"), setting: .string("??")), .off, "nothing readable: no sound")
        // A sandbox's: no device is off whatever the value; with it, on or else speakers (off keeps the device).
        XCTAssertEqual(SoundMode.of(hasDevice: false, value: on), .off)
        XCTAssertEqual(SoundMode.of(hasDevice: true, value: on), .on)
        XCTAssertEqual(SoundMode.of(hasDevice: true, value: speakers), .speakers)
        XCTAssertEqual(SoundMode.of(hasDevice: true, value: off), .speakers)
        XCTAssertTrue(SoundMode.on.wantsMicrophone && SoundMode.on.hasDevice)
        XCTAssertFalse(SoundMode.speakers.wantsMicrophone)
        XCTAssertTrue(SoundMode.speakers.hasDevice)
        XCTAssertFalse(SoundMode.off.hasDevice)
    }

    func testASandboxMovesOnlyBetweenSpeakersAndOn() {
        XCTAssertNil(SoundMode.changeProblem(hasDevice: true, to: .speakers, sandbox: "s"))
        XCTAssertNil(SoundMode.changeProblem(hasDevice: true, to: .on, sandbox: "s"))
        XCTAssertNil(SoundMode.changeProblem(hasDevice: false, to: .off, sandbox: "s"))
        XCTAssertTrue(SoundMode.changeProblem(hasDevice: true, to: .off, sandbox: "s")?.contains("created with sound") == true)
        XCTAssertTrue(SoundMode.changeProblem(hasDevice: false, to: .on, sandbox: "s")?.contains("chosen when a sandbox is created") == true)
    }

    func testTheSettingIsPerSandboxAndOffByDefault() throws {
        XCTAssertTrue(DozableSettings.perSandbox.contains(SettingKey.audio))
        let d = try XCTUnwrap(DozableSettings.definition(SettingKey.audio))
        XCTAssertEqual(d.defaultValue, .string("off"))
        XCTAssertEqual(try d.parse("speakers"), .string("speakers"))
        XCTAssertThrowsError(try d.parse("loud"))
        XCTAssertTrue(DozableProject.settingKeys.contains { $0.key == "audio" && $0.setting == SettingKey.audio }, "audio: in doz_project.yaml")
    }

    /// The microphone is the Mac's ONLY when macOS has already said yes — never while its question is open (604: a
    /// recording stuck before Allow; the VM stopped by a pause with the question pending).
    func testTheMicrophoneIsTheMacsOnlyWhenAllowed() {
        XCTAssertEqual(MicrophoneDecision.decide(wanted: true, permission: .allowed, app: "Terminal"), .mac)
        for p in [MicrophonePermission.denied, .undecided, .restricted] {
            let d = MicrophoneDecision.decide(wanted: true, permission: p, app: "Terminal")
            XCTAssertFalse(d.isMac, "\(p)")
            if case .silent(let why) = d { XCTAssertFalse(why.isEmpty) }
        }
        if case .silent(let why) = MicrophoneDecision.decide(wanted: true, permission: .denied, app: "Terminal") {
            XCTAssertTrue(why.contains("Terminal") && why.contains("Privacy & Security"), why)
        }
        for p in MicrophonePermission.allCases {
            XCTAssertFalse(MicrophoneDecision.decide(wanted: false, permission: p, app: nil).isMac, "speakers only: never the microphone (\(p))")
        }
    }

    /// No test ever reaches macOS's real microphone permission: a guarded run (and every XCTest) gets the seam.
    func testATestNeverReachesTheRealPermission() async {
        XCTAssertTrue(MicrophoneAccess.current([:]).seamed, "inside XCTest: the seam")
        XCTAssertTrue(MicrophoneAccess.current(["DOZ_TEST_GUARD": "1"]).seamed)
        let none = MicrophoneAccess.seam([:])
        XCTAssertEqual(none.status(), .undecided)
        let asked = await none.request(.milliseconds(10))
        XCTAssertNil(asked, "no answer seamed: the question goes unanswered")
        let allowed = MicrophoneAccess.seam(["DOZ_TEST_MICROPHONE": "allowed"])
        XCTAssertEqual(allowed.status(), .allowed)
        let answered = MicrophoneAccess.seam(["DOZ_TEST_MICROPHONE": "undecided", "DOZ_TEST_MICROPHONE_ANSWER": "allowed"])
        let answer = await answered.request(.seconds(1))
        XCTAssertEqual(answer, .allowed)
        let denied = MicrophoneAccess.seam(["DOZ_TEST_MICROPHONE": "denied", "DOZ_TEST_MICROPHONE_ANSWER": "allowed"])
        let kept = await denied.request(.seconds(1))
        XCTAssertEqual(kept, .denied, "a decided answer is not asked again")
    }

    // MARK: 667 — when doz asks (owner, 2026-10-27: "make it configurable (default to when first records)")

    func testWhenDozAsksIsASettingThatDefaultsToTheFirstRecording() throws {
        let d = try XCTUnwrap(DozableSettings.definition(SettingKey.microphoneAsk))
        XCTAssertEqual(d.defaultValue, .string("first_recording"))
        XCTAssertEqual(try d.parse("first_start"), .string("first_start"))
        XCTAssertThrowsError(try d.parse("never"))
        XCTAssertFalse(DozableSettings.perSandbox.contains(SettingKey.microphoneAsk), "macOS's answer is the Mac's, not a sandbox's")
        XCTAssertEqual(MicrophoneAsk.of(.string("first_start")), .firstStart)
        XCTAssertEqual(MicrophoneAsk.of(.string("??")), .firstRecording, "unreadable: the default")
        XCTAssertEqual(MicrophoneAsk.of(d.defaultValue), .firstRecording)
    }

    /// Asking at the first recording: a start never asks, the decision says when doz will, and what doz says after the
    /// answer is the truth about the VM — that recording stays silent until a Shut Down and Start.
    func testAskingAtTheFirstRecordingIsSaidPlainly() {
        guard case .silent(let atRecording) = MicrophoneDecision.decide(wanted: true, permission: .undecided, app: "Terminal", ask: .firstRecording),
              case .silent(let atStart) = MicrophoneDecision.decide(wanted: true, permission: .undecided, app: "Terminal", ask: .firstStart)
        else { return XCTFail("undecided is silent either way") }
        XCTAssertTrue(atRecording.contains("first records") && atRecording.contains("Shut Down and Start"), atRecording)
        XCTAssertTrue(atStart.contains("answer its question"), atStart)
        XCTAssertEqual(MicrophoneDecision.decide(wanted: true, permission: .allowed, app: nil, ask: .firstRecording), .mac)
        let allowed = MicrophoneDecision.answeredAtRecording(.allowed, sandbox: "s1", app: "Terminal")
        XCTAssertTrue(allowed.contains("this recording is silent") && allowed.contains("Shut Down and Start s1"), allowed)
        let denied = MicrophoneDecision.answeredAtRecording(.denied, sandbox: "s1", app: "Terminal")
        XCTAssertTrue(denied.contains("denied") && denied.contains("Privacy & Security"), denied)
        let none = MicrophoneDecision.answeredAtRecording(nil, sandbox: "s1", app: nil)
        XCTAssertTrue(none.contains("did not answer") && none.contains("the app that started doz"), none)
        XCTAssertTrue(MicrophonePermission.undecided.sentence(ask: .firstRecording).contains("first records"))
        XCTAssertTrue(MicrophonePermission.undecided.sentence(ask: .firstStart).contains("first starts"))
    }

    /// The host watches a running sandbox for its first recording ONLY when that is when it asks: the microphone
    /// wanted, first_recording, macOS undecided, and a VM not already built with the Mac's microphone.
    func testTheWatchRunsOnlyWhenARecordingWouldAsk() {
        XCTAssertTrue(HostCore.watchesForRecording(mode: .on, ask: .firstRecording, permission: .undecided, builtWithMac: false))
        XCTAssertTrue(HostCore.watchesForRecording(mode: .on, ask: .firstRecording, permission: .undecided, builtWithMac: nil))
        XCTAssertFalse(HostCore.watchesForRecording(mode: .speakers, ask: .firstRecording, permission: .undecided, builtWithMac: false))
        XCTAssertFalse(HostCore.watchesForRecording(mode: .on, ask: .firstStart, permission: .undecided, builtWithMac: false))
        for p in [MicrophonePermission.allowed, .denied, .restricted] {
            XCTAssertFalse(HostCore.watchesForRecording(mode: .on, ask: .firstRecording, permission: p, builtWithMac: false), "\(p): nothing to ask")
        }
        XCTAssertFalse(HostCore.watchesForRecording(mode: .on, ask: .firstRecording, permission: .undecided, builtWithMac: true))
    }

    /// Like macOS, the seam keeps the answer to its question: a later look (the next cold boot) sees it.
    func testTheSeamRemembersItsAnswer() async {
        let seam = MicrophoneAccess.seam(["DOZ_TEST_MICROPHONE": "undecided", "DOZ_TEST_MICROPHONE_ANSWER": "allowed"])
        XCTAssertEqual(seam.status(), .undecided)
        let answer = await seam.request(.seconds(1))
        XCTAssertEqual(answer, .allowed)
        XCTAssertEqual(seam.status(), .allowed)
        let unanswered = MicrophoneAccess.seam(["DOZ_TEST_MICROPHONE": "undecided"])
        let none = await unanswered.request(.milliseconds(10))
        XCTAssertNil(none)
        XCTAssertEqual(unanswered.status(), .undecided)
    }

    func testTheResponsibleAppIsNamedWhenMacOSKnowsIt() {
        // Whatever runs the tests (a terminal, an editor) — named, with a path, or nil; never a crash.
        if let app = MacAudio.responsibleApp() {
            XCTAssertFalse(app.name.isEmpty)
            XCTAssertTrue(app.path.hasPrefix("/"))
            XCTAssertGreaterThan(app.pid, 0)
        }
        XCTAssertNil(ToolInputs(github: false).audio)
    }
}
