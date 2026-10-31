import Foundation

// 653 — where a recipe came from. Dozable's own (this build's embedded set, or its signed catalogue), the person's own
// (`<settings dir>/recipes/mine/<id>.yaml`), or a community catalogue the person added by its URL and key and confirmed.
// Kept OUTSIDE a recipe's coding keys: its JSON, canonical form and every bake key are what they were (RecipePinTests).

/// A recipe's origin, and the label everything that shows a recipe carries.
public struct RecipeOrigin: Codable, Equatable, Hashable, Sendable {
    /// `dozable` | `mine` | `community`.
    public var kind: String
    /// community: the source's name (`[a-z0-9-]`, the person's or the URL's host).
    public var source: String?

    public init(kind: String, source: String? = nil) {
        self.kind = kind
        self.source = source
    }

    public static let dozable = RecipeOrigin(kind: "dozable")
    public static let mine = RecipeOrigin(kind: "mine")
    public static func community(_ name: String) -> RecipeOrigin { RecipeOrigin(kind: "community", source: name) }

    public var isDozable: Bool { kind == "dozable" }
    public var isMine: Bool { kind == "mine" }
    public var isCommunity: Bool { kind == "community" }

    /// What a person reads beside the recipe: nothing for Dozable's own, "yours", "community · NAME".
    public var label: String? {
        switch kind {
        case "mine": return "yours"
        case "community": return "community · " + (source ?? "?")
        default: return nil
        }
    }

    /// The same, capitalised, for a pill ("Yours", "Community · NAME").
    public var title: String? {
        label.map { $0.prefix(1).uppercased() + $0.dropFirst() }
    }

    /// A source's name: lower-case letters, digits and dashes, 1–32.
    public static func isSourceName(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$", options: .regularExpression) != nil
    }

    /// 670: Dozable's recipe directory — the host that serves the signed recipe catalogue (`Distribution.recipeCatalogueURL`;
    /// a test ties the two, DozableKit cannot see `Distribution`). `doz.sh/VENDOR/PRODUCT` names Dozable's own recipe.
    public static let directoryHost = "doz.sh"

    /// 654: the SOURCE words of a qualified name (`dozable/…`, `mine/…`) — never a community source's name.
    public static let reservedSourceNames: Set<String> = ["dozable", "mine"]

    /// 654: the first part of a qualified name for a recipe of this origin (`dozable`, `mine`, the source's name).
    public var sourceWord: String {
        switch kind {
        case "mine": return "mine"
        case "community": return source ?? "community"
        default: return "dozable"
        }
    }
}
