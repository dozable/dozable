import Darwin
import Foundation
import XCTest
@testable import DozableKit
@testable import DozableHost

/// A semaphore waited for from synchronous code (the tests are async).
private func blockOn(_ s: DispatchSemaphore, seconds: Double = 10) { _ = s.wait(timeout: .now() + seconds) }

/// 676: the host's frame pump (`AgentStreamRelay`) over a real socketpair with a real `AgentPipe` and no VM — the order of
/// stdout and stderr, `E` last with the exit code or the severed word, the client's input and its end, the hang-up (stdin EOF,
/// then the program ended after the grace period unless it exited), an unknown client frame, and back-pressure both ways.
final class AgentStreamRelayTests: XCTestCase {
    /// A relay running on its own thread, and the client's end of the socket.
    final class Rig: @unchecked Sendable {
        let pipe: AgentPipe
        let client: Int32
        let relay: AgentStreamRelay
        let done = DispatchSemaphore(value: 0)
        let ended = ByteCount()           // endProgram calls
        let slept = ByteCount()           // grace sleeps asked (in seconds)
        let inputs = ByteCount()
        var outcome: AgentStreamRelay.Outcome?

        init(highWater: Int = 4 << 20, inputLimit: Int = 1 << 20, stopping: Bool = false,
             sleep: (@Sendable (Duration) async -> Void)? = nil) {
            var fds: [Int32] = [0, 0]
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            client = fds[1]
            UnixSocket.noSigPipe(client)
            let pipe = AgentPipe(label: "t", argv0: "agent", highWater: highWater, inputLimit: inputLimit)
            self.pipe = pipe
            let ended = self.ended, slept = self.slept, inputs = self.inputs
            pipe.setOnEndProgram { ended.add(1); pipe.ended(nil) }
            relay = AgentStreamRelay(conn: HostConnection(fd: fds[0]), pipe: pipe, grace: .seconds(5),
                                     sleep: { d in slept.add(Int(d.components.seconds)); await sleep?(d) },
                                     onInput: { inputs.add(1) }, hostStopping: { stopping })
            Thread.detachNewThread { [self] in
                outcome = relay.run()
                done.signal()
            }
        }

        func send(_ type: UInt8, _ s: String = "") { _ = UnixSocket.writeAll(client, AgentFrame.encode(type, Data(s.utf8))) }

        /// Every frame until the host closes (or `limit` seconds).
        func frames(limit: Double = 5) -> [(type: UInt8, payload: Data)] {
            let parser = AgentFrame.clientParser()
            var out: [(type: UInt8, payload: Data)] = []
            var buf = [UInt8](repeating: 0, count: 65_536)
            let deadline = Date().addingTimeInterval(limit)
            while Date() < deadline {
                let n = read(client, &buf, buf.count)
                if n <= 0 { break }
                out += (try? parser.feed(Data(buf[0..<n]))) ?? []
            }
            return out
        }

        func finish() -> AgentStreamRelay.Outcome? {
            blockOn(done, seconds: 5)
            close(client)
            return outcome
        }
    }

    func testStdoutAndStderrInOrderThenTheEndLast() throws {
        let r = Rig()
        r.pipe.write(stdout: Data("{\"type\":\"system\"}\n".utf8))
        r.pipe.write(stderr: Data("warn\n".utf8))
        r.pipe.write(stdout: Data("{\"type\":\"result\"}\n".utf8))
        r.pipe.ended(0)
        let f = r.frames()
        XCTAssertEqual(f.map(\.type), [AgentFrame.data, AgentFrame.stderr, AgentFrame.data, AgentFrame.end])
        XCTAssertEqual(f[1].payload, Data("warn\n".utf8))
        let end = try HostWire.decoder.decode(AgentStreamEnd.self, from: f[3].payload)
        XCTAssertEqual(end.exitCode, 0)
        XCTAssertNil(end.severed)
        XCTAssertEqual(end.stdoutBytes, 36)
        let o = try XCTUnwrap(r.finish())
        XCTAssertTrue(o.delivered)
        XCTAssertFalse(o.clientGone)
        XCTAssertEqual(r.ended.value, 0, "an exited program is never ended again")
    }

    func testEachWayItIsSevered() throws {
        for (reason, stopping, word) in [(DetachReason.sandboxSleeping, false, "sleeping"), (.sandboxStopped, false, "stopped"),
                                         (.sandboxSleeping, true, "host-stopping"), (.transportLost, false, "transport-lost")] {
            let r = Rig(stopping: stopping)
            r.pipe.write(stdout: Data("partial".utf8))
            r.pipe.sever(reason)
            let f = r.frames()
            XCTAssertEqual(f.map(\.type), [AgentFrame.data, AgentFrame.end], word)
            let end = try HostWire.decoder.decode(AgentStreamEnd.self, from: f.last!.payload)
            XCTAssertEqual(end.severed, word)
            XCTAssertNil(end.exitCode, "never both")
            _ = r.finish()
        }
        // Neither an exit code nor a reason: transport-lost.
        let r = Rig()
        r.pipe.ended(nil)
        let end = try HostWire.decoder.decode(AgentStreamEnd.self, from: try XCTUnwrap(r.frames().last).payload)
        XCTAssertEqual(end.severed, "transport-lost")
        _ = r.finish()
    }

    func testTheClientsInputAndItsEnd() async throws {
        let r = Rig()
        r.send(AgentFrame.data, "{\"type\":\"user\"}\n")
        r.send(AgentFrame.data, "second\n")
        r.send(AgentFrame.finish)
        var got = Data()
        while let d = await r.pipe.input.take() { got.append(d) }
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "{\"type\":\"user\"}\nsecond\n")
        XCTAssertEqual(r.inputs.value, 2, "each D frame is input (the wake rule)")
        r.pipe.ended(0)
        let end = try HostWire.decoder.decode(AgentStreamEnd.self, from: try XCTUnwrap(r.frames().last).payload)
        XCTAssertEqual(end.stdinBytes, Int64(got.count))
        _ = r.finish()
    }

    /// A client that hangs up: the program's stdin ends at once; after the grace period it is ended — no `E` (nobody listens).
    func testAHangUpClosesStdinThenEndsTheProgramAfterTheGrace() async throws {
        let r = Rig()
        r.pipe.write(stdout: Data("hello".utf8))
        close(r.client)
        let waited = await Task.detached { blockOn(r.done); return r.outcome }.value
        let o = try XCTUnwrap(waited)
        XCTAssertTrue(o.clientGone)
        XCTAssertFalse(o.delivered)
        let eof = await r.pipe.input.take()
        XCTAssertNil(eof, "its stdin is at EOF")
        await r.relay.graceTask?.value
        XCTAssertEqual(r.slept.value, 5, "the grace is 5 s")
        XCTAssertEqual(r.ended.value, 1, "then the program is ended")
    }

    /// …unless it exits within the grace.
    func testNoKillWhenTheProgramExitsWithinTheGrace() async throws {
        let release = DispatchSemaphore(value: 0)
        let r = Rig(sleep: { _ in await Task.detached { blockOn(release) }.value })
        close(r.client)
        await Task.detached { blockOn(r.done) }.value
        r.pipe.ended(0)                                       // it saw EOF and ended
        release.signal()
        await r.relay.graceTask?.value
        XCTAssertEqual(r.ended.value, 0)
    }

    /// A client frame of a type the host does not know is a hang-up.
    func testAnUnknownClientFrameIsAHangUp() async throws {
        let r = Rig()
        r.send(0x5A, "?")
        let eof = await r.pipe.input.take()
        XCTAssertNil(eof)
        await Task.detached { while r.relay.graceTask == nil { usleep(10_000) } }.value
        await r.relay.graceTask?.value
        XCTAssertEqual(r.ended.value, 1)
        _ = r.finish()
    }

    /// A slow client: the program's output is held at most at the mark, nothing is lost, and the order is kept.
    func testBackPressureFromASlowClient() throws {
        let r = Rig(highWater: 64 << 10)
        let total = 4 << 20, chunk = 16 << 10
        let wrote = expectation(description: "the guest's writer")
        Thread.detachNewThread {
            var i = 0
            while i * chunk < total {
                r.pipe.write(stdout: Data(repeating: UInt8(i & 0xFF), count: chunk))
                i += 1
            }
            r.pipe.ended(0)
            wrote.fulfill()
        }
        let parser = AgentFrame.clientParser()
        var got = Data()
        var end: AgentStreamEnd?
        var buf = [UInt8](repeating: 0, count: 4096)
        var reads = 0
        while end == nil {
            let n = read(r.client, &buf, buf.count)
            if n <= 0 { break }
            for f in try parser.feed(Data(buf[0..<n])) {
                if f.type == AgentFrame.data { got.append(f.payload) } else if f.type == AgentFrame.end {
                    end = try HostWire.decoder.decode(AgentStreamEnd.self, from: f.payload)
                }
            }
            reads += 1
            if reads % 64 == 0 { usleep(2_000) }
            XCTAssertLessThanOrEqual(r.pipe.output.buffered, 64 << 10)
        }
        wait(for: [wrote], timeout: 30)
        XCTAssertEqual(got.count, total, "nothing lost")
        for i in stride(from: 0, to: total, by: chunk) { if got[i] != UInt8((i / chunk) & 0xFF) { XCTFail("out of order at \(i)"); break } }
        XCTAssertLessThanOrEqual(r.pipe.output.peak, 64 << 10, "never above the high-water mark")
        XCTAssertEqual(end?.exitCode, 0)
        _ = r.finish()
    }

    /// A guest that does not take its input: the host stops reading at 1 MiB queued, so the client's write blocks.
    func testBackPressureIntoAProgramThatDoesNotRead() async throws {
        let r = Rig(inputLimit: 256 << 10)
        let sent = ByteCount()
        let writer = expectation(description: "the client's writes")
        Thread.detachNewThread {
            let piece = Data(repeating: 7, count: 32 << 10)
            for _ in 0..<64 { if UnixSocket.writeAll(r.client, AgentFrame.encode(AgentFrame.data, piece)) { sent.add(piece.count) } }
            writer.fulfill()
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertLessThanOrEqual(r.pipe.input.queuedBytes, 256 << 10)
        XCTAssertLessThan(sent.value, 2 << 20, "the client is held back")
        var got = 0
        while got < 2 << 20, let d = await r.pipe.input.take() { got += d.count }
        await fulfillment(of: [writer], timeout: 10)
        XCTAssertEqual(got, 2 << 20)
        r.pipe.ended(0)
        _ = r.frames()
        _ = r.finish()
    }
}
