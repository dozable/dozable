import ArgumentParser
import DozableHost
import Foundation

/// `doz help exit-codes [--json]`: the published exit-code table (`ExitCodes`), for a person or a script. Changes
/// nothing, never starts the daemon. `DozableEntry` takes the two words before ArgumentParser parses (it owns `help`).
struct HelpExitCodes: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doz help exit-codes",
        abstract: "Print doz's exit codes: each code, its name, what it means and the error codes --json carries with it.",
        discussion: """
        The table is frozen: a code keeps its meaning and a new outcome gets a new code. --json prints \
        {"kind":"ExitCodes","schema":1,"codes":[{"exit","name","meaning","errorCodes"}…]}.
        """)
    @OptionGroup var g: GlobalOptions

    static func isAsked(_ args: [String]) -> Bool { args.count >= 2 && args[0] == "help" && args[1] == "exit-codes" }

    func run() throws {
        if g.json { Out.json(ExitCodesAnswer()); return }
        Out.stdout(ExitCodes.text)
    }
}
