import Foundation

// The live stream of the human's page (`GET /api/stream`): what happened, as events, to every open page. Each open
// page is one subscriber with a queue of `queueSize` events; a subscriber whose queue is full has fallen behind and lost
// events, so it is closed and dropped — its stream sends what is still queued, then `resync`, and ends, and the page
// reconnects and reads the log again instead of missing events silently. Transport-free: the page listener writes what
// `next()` hands it.

/// One event of the stream: `{"kind":…,"room":…}` and, by kind, a message, a state, the presence list or a reaction.
public struct ChatEvent: Sendable {
    public var kind: String
    public var room = ""
    public var message: ChatStored?
    public var state: ChatState?
    public var presence: [JValue]?
    public var reaction: JValue?

    public init(kind: String, room: String = "", message: ChatStored? = nil, state: ChatState? = nil, presence: [JValue]? = nil) {
        self.kind = kind; self.room = room; self.message = message; self.state = state; self.presence = presence
    }

    /// The protocol's shape: kind and room always; the others only when there is one.
    public var json: JValue {
        var o = JObject()
        o.add("kind", .string(kind))
        o.add("room", .string(room))
        if let message { o.add("message", message.json) }
        if let state { o.add("state", state.json) }
        if let presence, !presence.isEmpty { o.add("presence", .array(presence)) }
        if let reaction { o.add("reaction", reaction) }
        return o.value
    }

    /// The bytes of one event on the stream: one `data:` line and a blank line.
    public var frame: [UInt8] { Array("data: ".utf8) + ChatJSON.encode(json) + Array("\n\n".utf8) }
}

/// One open page's queue.
public final class ChatSubscriber: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [ChatEvent] = []
    private var closed = false
    private var behind = false
    private var waiter: CheckedContinuation<Void, Never>?

    /// How many events wait for one subscriber before it counts as fallen behind.
    public static let queueSize = 64

    /// Adds an event; false when the queue was full (the subscriber is then closed as behind).
    func offer(_ e: ChatEvent) -> Bool {
        lock.lock()
        if closed { lock.unlock(); return true }
        if queue.count >= Self.queueSize {
            closed = true
            behind = true
            let w = waiter; waiter = nil
            lock.unlock()
            w?.resume()
            return false
        }
        queue.append(e)
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume()
        return true
    }

    /// Ends the stream without a resync: the page went away, or the server stops.
    public func cancel() {
        lock.lock()
        closed = true
        let w = waiter; waiter = nil
        lock.unlock()
        w?.resume()
    }

    public enum Next: Sendable { case event(ChatEvent), resync, end }

    /// The next event; then, once closed and drained, `resync` when it fell behind, else `end`.
    public func next() async -> Next {
        while true {
            if let n = take() { return n }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in park(c) }
        }
    }

    private func take() -> Next? {
        lock.withLock {
            if !queue.isEmpty { return .event(queue.removeFirst()) }
            guard closed else { return nil }
            defer { behind = false }
            return behind ? .resync : .end
        }
    }

    private func park(_ c: CheckedContinuation<Void, Never>) {
        let now: Bool = lock.withLock {
            if !queue.isEmpty || closed { return true }
            waiter = c
            return false
        }
        if now { c.resume() }
    }
}

/// Every open page's subscriber.
final class ChatEventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var subs: [ObjectIdentifier: ChatSubscriber] = [:]

    func subscribe() -> ChatSubscriber {
        let s = ChatSubscriber()
        lock.withLock { subs[ObjectIdentifier(s)] = s }
        return s
    }

    func unsubscribe(_ s: ChatSubscriber) { lock.withLock { _ = subs.removeValue(forKey: ObjectIdentifier(s)) } }

    var count: Int { lock.withLock { subs.count } }

    /// Hands the event to every subscriber; one that is behind is closed and dropped.
    func publish(_ e: ChatEvent) {
        let all = lock.withLock { Array(subs.values) }
        for s in all where !s.offer(e) { unsubscribe(s) }
    }

    func closeAll() {
        let all = lock.withLock { () -> [ChatSubscriber] in defer { subs = [:] }; return Array(subs.values) }
        for s in all { s.cancel() }
    }
}
