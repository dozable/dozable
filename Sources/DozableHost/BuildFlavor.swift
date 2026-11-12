import Foundation

/// 611: what a PUBLIC build of doz leaves out — decided at build time (`make release PUBLIC=1`, the default for real
/// releases, compiles with `-DDOZ_PUBLIC_BUILD`), never by a setting a person could flip.
///
/// - **Dozable's own ChatGPT sign-in** (`doz account add NAME --chatgpt`, the onboarding's and the create preflight's
///   "sign in with ChatGPT") — it signs in with Codex's PUBLIC client id, which is Codex's to use. A public build
///   keeps Codex's other two ways in: the account `mac` (this Mac's own Codex login, read-only) and an OpenAI API key.
///   A ChatGPT account an earlier build put in a store is kept, never used: every request says why.
/// - **The sound kernel** (`doz create --sound`, `--audio`, `sandbox.audio`): not in the tarball (a GPL kernel Dozable
///   builds: a release that carries it carries its source offer, 667). `--sound` then says this build does not include it.
///
/// Tests reach both modes without two builds: every decision takes a `BuildFlavor`, and a real process can be
/// told which one it is with the TEST seam `DOZ_TEST_PUBLIC_BUILD=1|0`.
public struct BuildFlavor: Sendable, Equatable {
    public var isPublic: Bool
    /// 675: the HELPER build (`make release FLAVOUR=helper`, `-DDOZ_HELPER_BUILD`): the doz an app carries inside its
    /// bundle and drives over host.sock. The same host and protocol as the CLI; it never updates itself (the app
    /// does), `ping` says `flavour: "helper"`, and it has no dashboard and no setup wizards. Independent of `isPublic`.
    public var isHelper: Bool
    public init(isPublic: Bool, isHelper: Bool = false) {
        self.isPublic = isPublic
        self.isHelper = isHelper
    }

    public static let publicBuild = BuildFlavor(isPublic: true)
    public static let privateBuild = BuildFlavor(isPublic: false)

    /// How this binary was compiled.
    public static let compiled: BuildFlavor = {
        #if DOZ_HELPER_BUILD
        let helper = true
        #else
        let helper = false
        #endif
        #if DOZ_PUBLIC_BUILD
        return BuildFlavor(isPublic: true, isHelper: helper)
        #else
        return BuildFlavor(isPublic: false, isHelper: helper)
        #endif
    }()

    /// This process's flavor: the compiled one, unless the test seams say otherwise.
    public static var current: BuildFlavor { from(ProcessInfo.processInfo.environment) }

    /// `DOZ_TEST_PUBLIC_BUILD=1|0` and `DOZ_TEST_HELPER_BUILD=1|0` (675) — test seams: a CLI build that says it is the
    /// helper only refuses its own updates and reports `helper`; what the helper leaves out is decided at compile time.
    public static func from(_ env: [String: String], compiled: BuildFlavor = .compiled) -> BuildFlavor {
        var f = compiled
        switch env["DOZ_TEST_PUBLIC_BUILD"] {
        case "1": f.isPublic = true
        case "0": f.isPublic = false
        default: break
        }
        switch env["DOZ_TEST_HELPER_BUILD"] {
        case "1": f.isHelper = true
        case "0": f.isHelper = false
        default: break
        }
        return f
    }

    /// 675: what `ping` (host status) reports as `flavour` — `cli` (Homebrew, the release tarball) or `helper`.
    public var flavourName: String { isHelper ? "helper" : "cli" }

    /// The app a helper build belongs to: the name of the `.app` bundle its executable sits in
    /// (`SandboxLab.app/Contents/Resources/Helpers/doz/doz` → SandboxLab), or nil.
    public static func owningApp(executable: String) -> String? {
        let parts = URL(fileURLWithPath: executable).resolvingSymlinksInPath().pathComponents
        guard let app = parts.last(where: { $0.hasSuffix(".app") && $0.count > 4 }) else { return nil }
        return String(app.dropLast(4))
    }

    /// 675: why a helper build never updates itself (`doz upgrade` refuses, no update checks).
    public static func helperUpdates(app: String?) -> String {
        if let app {
            return "this doz belongs to \(app); \(app) updates it — it never updates itself"
        }
        return "this doz is the helper build an app carries inside it; the app updates it — it never updates itself"
    }

    /// 675: what a helper build leaves out (`doz ui`, `doz serve`, the setup wizards) — said by the command.
    public static func helperLeavesOut(_ what: String) -> String {
        "\(what) is not in this build — this doz is the helper build an app carries (no dashboard, no setup wizards); "
            + "the app is its interface. The doz command from Homebrew has it"
    }

    /// Dozable's own ChatGPT sign-in is part of this build.
    public var chatgptSignIn: Bool { !isPublic }

    /// Why a ChatGPT sign-in cannot be made with this build.
    public static let chatgptSignInMissing =
        "this doz does not include Dozable's own ChatGPT sign-in. For Codex, use this Mac's own Codex login (the account mac: "
        + "sign in with codex on this Mac) or an OpenAI API key (doz account add NAME --openai-key)"

    /// Why an existing ChatGPT account (made by an earlier, pre-release doz) is not used.
    public static func chatgptAccountUnsupported(_ name: String) -> String {
        "the account \(name) is a ChatGPT sign-in, which this doz does not support — use this Mac's own Codex login "
            + "(doz account use SANDBOX mac) or an OpenAI API key (doz account add NAME --openai-key); doz account rm \(name) removes it"
    }

    /// Why sound (`--sound`, `--audio`, `sandbox.audio`) cannot be used with this build (a public build never carries
    /// the sound kernel — 667 keeps that until the owner decides how public releases ship it).
    public static let audioMissing =
        "this build of doz does not include sound (doz create --sound / --audio) — it is not part of public releases"
}
