import Foundation

// 669 (659 §3, owner: "a tool's settings come with its recipe") — the settings of a recipe's agent. Every recipe has the
// same few (`RecipeSettings.common`: version, approvals when it has prompts to skip, memory, network), generated for it;
// a recipe declares more only when its agent needs one of its own (`com.dozable/settings@1`: Codex's keep_alive). The
// settings schema (DozableHost's `DozableSettings`) is still CLOSED: it is generated from the active recipe set, and a
// recipe's block is decoded strictly with closed types — an unknown key or type is refused, as everywhere in a recipe.

/// One option of `com.dozable/settings@1`: a name, one of the closed types, its default, a one-line summary and when a
/// change applies. Its doz.toml key is `recipes.VENDOR.PRODUCT.NAME`; set on the Mac only (a sandbox or project layer is
/// the common options' — approvals).
public struct RecipeSettingOption: Codable, Sendable, Equatable {
    /// `[a-z][a-z0-9_]*`, never one of the common options' names.
    public var name: String
    /// `bool` | `int` | `choice` — closed.
    public var type: String
    /// `choice`: its words.
    public var choices: [String]? = nil
    /// `int`: its range.
    public var min: Int? = nil
    public var max: Int? = nil
    public var `default`: RecipeValue
    /// One line, said in doz.toml, `doz config show --agent` and the recipe's page.
    public var summary: String
    /// When a change applies: `now`, `next-session` or `next-create` (DozableHost's `SettingApplies` words).
    public var applies: String

    public init(name: String, type: String, choices: [String]? = nil, min: Int? = nil, max: Int? = nil,
                default value: RecipeValue, summary: String, applies: String) {
        self.name = name; self.type = type; self.choices = choices; self.min = min; self.max = max
        self.default = value; self.summary = summary; self.applies = applies
    }
}

public enum RecipeSettings {
    /// The options every recipe's agent has (659 §3), by name: its version, whether its approval prompts are skipped
    /// (a recipe with prompts to skip), and a new sandbox's memory and network.
    public static let version = "version"
    public static let approvals = "approvals"
    public static let memory = "memory_mib"
    public static let network = "network"
    public static let common = [version, approvals, memory, network]

    static let types = ["bool", "int", "choice"]
    static let appliesWords = ["now", "next-session", "next-create"]

    /// `com.dozable/settings@1`'s config.
    public struct Block: Codable, Sendable, Equatable {
        public var options: [RecipeSettingOption]
        public init(options: [RecipeSettingOption]) { self.options = options }
    }

    /// Why a recipe's own options are not valid (nil: they are).
    public static func problem(_ options: [RecipeSettingOption]) -> String? {
        guard !options.isEmpty, options.count <= 8 else { return "settings@1: 1 to 8 options" }
        var seen = Set<String>()
        for o in options {
            guard o.name.range(of: "^[a-z][a-z0-9_]{0,31}$", options: .regularExpression) != nil else { return "settings@1: \(o.name) is not a name ([a-z][a-z0-9_]*)" }
            guard !common.contains(o.name) else { return "settings@1: \(o.name) is one every recipe has" }
            guard seen.insert(o.name).inserted else { return "settings@1: \(o.name) twice" }
            guard types.contains(o.type) else { return "settings@1 \(o.name): type is bool, int or choice" }
            guard appliesWords.contains(o.applies) else { return "settings@1 \(o.name): applies is \(appliesWords.joined(separator: ", "))" }
            guard !o.summary.isEmpty, o.summary.count <= 600 else { return "settings@1 \(o.name): a summary of 1–600 characters" }
            switch (o.type, o.default) {
            case ("bool", .bool):
                guard o.choices == nil, o.min == nil, o.max == nil else { return "settings@1 \(o.name): a bool has no choices or range" }
            case ("int", .number(let n)):
                guard let lo = o.min, let hi = o.max, lo <= hi, n == n.rounded(), Double(lo) <= n, n <= Double(hi), o.choices == nil else {
                    return "settings@1 \(o.name): an int has min ≤ default ≤ max"
                }
            case ("choice", .string(let s)):
                guard let c = o.choices, !c.isEmpty, c.count <= 16, Set(c).count == c.count, c.contains(s), o.min == nil, o.max == nil,
                      c.allSatisfy({ $0.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) != nil }) else {
                    return "settings@1 \(o.name): a choice lists its words (the default among them)"
                }
            default:
                return "settings@1 \(o.name): its default is a \(o.type)"
            }
        }
        return nil
    }

    /// Why a subject is not one (nil: it is): a few lower-case words — `coding harness`, `agentic fortune teller`.
    public static func subjectProblem(_ s: String) -> String? {
        s.range(of: "^[a-z][a-z0-9]*( [a-z0-9][a-z0-9-]*){0,4}$", options: .regularExpression) != nil && s.count <= 40
            ? nil : "its subject (directory@1's description) is 1–5 lower-case words, at most 40 characters, like \"coding harness\""
    }
}
