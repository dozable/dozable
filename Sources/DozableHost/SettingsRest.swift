import Foundation

/// 678: the part of a `doz.toml` read that needs the recipes — its lines that are not Dozable's own keys (a recipe's
/// key, a 0.37 name, an unknown key, a `defaults.image` naming a recipe agent). Every `doz` start reads the file, and
/// most need only `store.path` and the telemetry switch: building every recipe's settings for that cost ~20 ms of a debug
/// build's start on an idle Mac and ~125 ms at background priority (measured). Settled once, the first time a value, warning, unknown key or migration
/// note of it is asked for — with the same result `DozableSettings.init(text:)` gave before (`SettingsLazySchemaTests`).
final class SettingsRest: @unchecked Sendable {
    struct Settled: Sendable {
        var values: [String: TOMLValue]
        var unknown: [TOMLEntry]
        var warnings: [String]
        var migrated: [String: String]
        var oldNames: Bool
    }

    private let lock = NSLock()
    private var pending: [(index: Int, entry: TOMLEntry)]
    private var core: [String: TOMLValue]
    private var coreWarnings: [(index: Int, line: String)]
    private var done: Settled?

    /// Already settled (no line needs a recipe).
    init(settled: Settled) {
        pending = []
        core = [:]
        coreWarnings = []
        done = settled
    }

    init(pending: [(index: Int, entry: TOMLEntry)], core: [String: TOMLValue], coreWarnings: [(index: Int, line: String)]) {
        self.pending = pending
        self.core = core
        self.coreWarnings = coreWarnings
    }

    /// Whether the recipes' part has been settled (a test asks).
    var isSettled: Bool { lock.withLock { done != nil } }

    var settled: Settled {
        lock.lock(); defer { lock.unlock() }
        if let done { return done }
        let s = DozableSettings.settle(pending, core: core, coreWarnings: coreWarnings)
        done = s
        pending = []
        core = [:]
        coreWarnings = []
        return s
    }
}

/// 678: a settings file's valid, known values (key → value). One of Dozable's own keys is answered from the core read
/// (`DozableSettings.isCoreFinal`); any other key, `all` or `count` settles the file's other lines first.
public struct FileValues: Sendable, Equatable, ExpressibleByDictionaryLiteral {
    let core: [String: TOMLValue]
    let rest: SettingsRest

    init(core: [String: TOMLValue], rest: SettingsRest) {
        self.core = core
        self.rest = rest
    }

    public init(dictionaryLiteral elements: (String, TOMLValue)...) {
        let d = Dictionary(elements, uniquingKeysWith: { $1 })
        self.init(core: d, rest: SettingsRest(settled: .init(values: d, unknown: [], warnings: [], migrated: [:], oldNames: false)))
    }

    public subscript(key: String) -> TOMLValue? {
        if let v = core[key] { return v }
        if DozableSettings.isCoreFinal(key) { return nil }
        return rest.settled.values[key]
    }

    /// Every value, as a dictionary.
    public var all: [String: TOMLValue] { rest.settled.values }
    public var count: Int { all.count }
    public var isEmpty: Bool { all.isEmpty }

    public static func == (a: FileValues, b: FileValues) -> Bool { a.all == b.all }
}
