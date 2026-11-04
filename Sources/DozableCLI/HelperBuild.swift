import ArgumentParser
import Foundation
import DozableHost

// 675 — what the HELPER build (`make release FLAVOUR=helper`; Package.swift's DOZ_HELPER_BUILD) answers for the commands
// it leaves out. An app carries the helper inside its bundle and drives it over host.sock; the host, the protocol and the
// read-only commands are the CLI's. Left out at compile time: the dashboard (`doz ui`, `doz serve` — DOZ_NO_WEB, so
// DozableWeb is not linked and its bundle not built) and the setup wizards (`doz onboard`, `doz init`, `doz try`).
// Each of those names still parses — so a person who types one is told why, instead of "unknown command".

/// The answer of a command a build leaves out: the reason on stderr (`--json`: as an error object on stdout), exit 1.
struct LeftOutCommand {
    static func refuse(_ what: String, _ args: [String]) throws -> Never {
        let message = BuildFlavor.helperLeavesOut(what)
        if args.contains("--json") {
            let body = ["error": ["code": HostError.Code.notImplemented.rawValue, "message": message]]
            if let d = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]) {
                FileHandle.standardOutput.write(d + Data("\n".utf8))
            }
        } else {
            FileHandle.standardError.write(Data("doz: \(message)\n".utf8))
        }
        throw ExitCode(DozableExit.failed)
    }
}

#if DOZ_NO_WEB
/// `doz ui` in a build without the dashboard.
struct UICommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ui",
        abstract: "The dashboard in your browser — not in this build (the helper build an app carries; the app is its interface).")
    @Argument(parsing: .captureForPassthrough, help: .hidden) var rest: [String] = []
    func run() throws { try LeftOutCommand.refuse("doz ui (the dashboard)", rest) }
}

/// `doz serve` in a build without the dashboard.
struct ServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve",
        abstract: "The dashboard on your network — not in this build (the helper build an app carries).")
    @Argument(parsing: .captureForPassthrough, help: .hidden) var rest: [String] = []
    func run() throws { try LeftOutCommand.refuse("doz serve (the dashboard)", rest) }
}

/// The dashboard's lock files, which `doz uninstall` and `doz nuke` check (a CLI build's `doz ui` may serve the same
/// store): the same names as DozableWeb's `WebControl` and `WebServeControl`.
enum WebControl {
    static func lockFile(_ store: DozableStore) -> URL { store.root.appendingPathComponent("ui.lock") }
}
enum WebServeControl {
    static func lockFile(_ root: URL) -> URL { root.appendingPathComponent("serve.lock") }
}
#endif

#if DOZ_HELPER_BUILD
/// The setup wizards and `doz try`, in the helper build.
enum HelperLeftOut {
    struct Onboard: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "onboard",
            abstract: "Set up this Mac — not in this build (the helper build an app carries; the app sets up).")
        @Argument(parsing: .captureForPassthrough, help: .hidden) var rest: [String] = []
        func run() throws { try LeftOutCommand.refuse("doz onboard (the setup wizard)", rest) }
    }

    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "init",
            abstract: "Give a folder a project file — not in this build (the helper build an app carries).")
        @Argument(parsing: .captureForPassthrough, help: .hidden) var rest: [String] = []
        func run() throws { try LeftOutCommand.refuse("doz init (the project wizard)", rest) }
    }

    struct Try: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "try",
            abstract: "Try an agent in one command — not in this build (the helper build an app carries).")
        @Argument(parsing: .captureForPassthrough, help: .hidden) var rest: [String] = []
        func run() throws { try LeftOutCommand.refuse("doz try", rest) }
    }
}
#endif
