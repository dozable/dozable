import Darwin
import Foundation
import DozableKit
@testable import DozableHost
import XCTest
@testable import DozableWeb

/// The setup wizard's Usage statistics step on a REAL listener: the session's projection (an official build only — a
/// FAKE installed package here, nothing reaches a network), read-only when DO_NOT_TRACK or the variable decides, and
/// the step's save path — the ordinary settings route, one typed change into a scratch XDG_CONFIG_HOME.
final class WebUsageStatsTests: XCTestCase {
    var server: DozableWebServer!
    var serveTask: Task<Void, Error>!
    let capability = try! WebBootstrapCapability(testingValue: "test-capability-abcdefghijklmnopqrstuvwxyz")
    let fake = FakeData()
    var xdg: URL!
    var env: [String: String] { ["XDG_CONFIG_HOME": xdg.path] }

    override func setUp() async throws {
        xdg = FileManager.default.temporaryDirectory.appendingPathComponent("doz-webusage-\(UUID().uuidString.prefix(8))")
    }

    func start(_ env: [String: String]) async throws {
        server = try await DozableWebServer.bind(data: fake, assets: try WebAssets.load(), version: "test",
                                                settings: WebSettingsStore(environment: env),
                                                capability: capability, pollInterval: .milliseconds(200))
        let s = server!
        serveTask = Task { try await s.run() }
    }

    override func tearDown() async throws {
        Usage.uninstall()
        await server?.close()
        _ = try? await serveTask?.value
        server = nil
        try? FileManager.default.removeItem(at: xdg)
    }

    func installFake() {
        Usage.install(send: { _ in }, flush: { _ in }, signup: { _ in SignupResult(status: "confirmation-sent") })
    }

    var origin: String { server.origin.value }

    func request(_ path: String, _ headers: [String: String] = [:], method: String = "GET", body: String? = nil) throws -> RawResponse {
        var h = ["Host": server.origin.authority]
        for (k, v) in headers { h[k] = v }
        return try RawHTTP.request(port: server.origin.port, method: method, path: path, headers: h, body: body)
    }

    func signIn() throws -> (String, String, [String: Any]) {
        let s = server!
        let link = try awaitValue { await s.newLink() }
        let cap = String(try XCTUnwrap(link.fragment).dropFirst("cap=".count))
        let r = try request("/api/v1/session", ["Origin": origin, "Authorization": "Bearer \(cap)"], method: "POST")
        XCTAssertEqual(r.status, 200, r.text)
        let pair = String(try XCTUnwrap(r.header("set-cookie")).split(separator: ";")[0])
        let info = try XCTUnwrap(try JSONSerialization.jsonObject(with: r.body) as? [String: Any])
        return (pair, try XCTUnwrap(info["csrf"] as? String), info)
    }

    func awaitValue<T: Sendable>(_ f: @escaping @Sendable () async -> T) throws -> T {
        let box = Box<T>()
        let sem = DispatchSemaphore(value: 0)
        Task { box.value = await f(); sem.signal() }
        guard sem.wait(timeout: .now() + 5) == .success, let v = box.value else { throw POSIXError(.ETIMEDOUT) }
        return v
    }
    final class Box<T>: @unchecked Sendable { var value: T? }

    func usage(_ info: [String: Any]) -> [String: Any]? { info["usageStats"] as? [String: Any] }

    func testAnOpenBuildHasNoStep() async throws {
        try await start(env)
        let (_, _, info) = try signIn()
        XCTAssertNil(info["usageStats"], "a build from the open-source repository sends nothing and shows no step")
    }

    func testTheProjectionIsTheStepFieldByField() async throws {
        installFake()
        try await start(env)
        let (_, _, info) = try signIn()
        let u = try XCTUnwrap(usage(info))
        XCTAssertEqual(Set(u.keys), ["on", "key", "summary", "showCommand", "privacyPage"], "fixed is absent (null) when the person decides")
        XCTAssertEqual(u["on"] as? Bool, true, "on by default")
        XCTAssertEqual(u["key"] as? String, "telemetry.send_anonymous_usage_stats")
        XCTAssertEqual(u["summary"] as? String, UsageStatsStep.summary)
        XCTAssertEqual(u["showCommand"] as? String, "doz telemetry show")
        XCTAssertEqual(u["privacyPage"] as? String, Usage.privacyPage)
    }

    func testDoNotTrackAndTheVariableAreShownReadOnly() async throws {
        installFake()
        try await start(env.merging(["DO_NOT_TRACK": "1"]) { $1 })
        let (_, _, dnt) = try signIn()
        XCTAssertEqual(usage(dnt)?["on"] as? Bool, false)
        XCTAssertTrue((usage(dnt)?["fixed"] as? String ?? "").contains("DO_NOT_TRACK"))
        await server.close()
        _ = try? await serveTask.value
        try await start(env.merging(["DOZ_SEND_ANONYMOUS_USAGE_STATS": "false"]) { $1 })
        let (cookie, csrf, viaEnv) = try signIn()
        XCTAssertEqual(usage(viaEnv)?["on"] as? Bool, false)
        XCTAssertTrue((usage(viaEnv)?["fixed"] as? String ?? "").contains("DOZ_SEND_ANONYMOUS_USAGE_STATS"))
        // The settings route refuses to change what the environment sets (the page never offers it).
        let r = try request("/api/v1/settings", ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json", "X-Doz-CSRF": csrf],
                            method: "POST", body: #"{"key":"telemetry.send_anonymous_usage_stats","value":true}"#)
        XCTAssertNotEqual(r.status, 200, r.text)
    }

    func testTheStepSavesThroughTheSettingsRouteAndTheNextSessionSaysSo() async throws {
        installFake()
        try await start(env)
        let (cookie, csrf, _) = try signIn()
        let headers = ["Cookie": cookie, "Origin": origin, "Content-Type": "application/json"]
        XCTAssertEqual(try request("/api/v1/settings", headers, method: "POST", body: #"{"key":"telemetry.send_anonymous_usage_stats","value":false}"#).status,
                       403, "CSRF as every unsafe route")
        XCTAssertNil(DozerSettings.load(environment: env).fileValues[SettingKey.sendUsageStats], "nothing written yet")
        let r = try request("/api/v1/settings", headers.merging(["X-Doz-CSRF": csrf]) { $1 }, method: "POST",
                            body: #"{"key":"telemetry.send_anonymous_usage_stats","value":false}"#)
        XCTAssertEqual(r.status, 200, r.text)
        XCTAssertEqual(DozerSettings.load(environment: env).fileValues[SettingKey.sendUsageStats], .bool(false))
        let (_, _, info) = try signIn()
        XCTAssertEqual(usage(info)?["on"] as? Bool, false)
        XCTAssertNil(usage(info)?["fixed"] as? String)
    }
}
