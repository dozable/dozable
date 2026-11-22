import ArgumentParser
import Foundation
import DozableHost
import DozableKit

// `doz skill …`: the skills doz carries for an agent that drives it (`ShippedSkills`: a SKILL.md each, in doz's resource
// bundle beside the executable). Read-only: nothing is installed, no daemon is started, the store is not read.

struct SkillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "skill",
        abstract: "The skills doz carries for an agent that drives it: doz skill show doz.",
        discussion: """
        A skill is a SKILL.md an agent loads: what Dozable is for, the commands, the exit codes and what not to do. doz \
        installs it nowhere — point your agent at the path doz skill show NAME --json gives.
        """,
        subcommands: [SkillShow.self])
}

/// `doz skill show NAME --json`.
struct SkillAnswer: Codable, Equatable, Sendable {
    var kind = "Skill"
    var schema = 1
    var name: String
    /// The absolute path of its SKILL.md.
    var path: String
}

struct SkillShow: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print a skill doz carries (doz: driving doz for a person).",
        discussion: """
        Prints its SKILL.md. --json prints {"kind":"Skill","schema":1,"name":NAME,"path":the absolute path of its SKILL.md} — \
        the file to give an agent. A skill this doz does not carry exits 2 (not-found), naming the ones it does.
        """)
    @OptionGroup var g: GlobalOptions
    @Argument(help: "The skill: doz.") var name: String

    /// The answer, or the error to fail with. `dir`: where the skills are (a test's folder; default this build's).
    static func resolve(_ name: String, in dir: URL? = ShippedSkills.directory()) -> Result<SkillAnswer, HostError> {
        let names = ShippedSkills.names(in: dir)
        guard !names.isEmpty else { return .failure(HostError(.failed, "this build of doz carries no skills (no \(ShippedSkills.folder) folder beside it)")) }
        guard let url = ShippedSkills.locate(name, in: dir) else {
            return .failure(HostError(.notFound, "no skill \(name.prefix(64)) — this doz carries: \(names.joined(separator: ", "))"))
        }
        return .success(SkillAnswer(name: name, path: url.path))
    }

    func run() throws {
        switch Self.resolve(name) {
        case .failure(let e): throw fail(e, g)
        case .success(let a):
            if g.json { Out.json(a); return }
            guard let d = FileManager.default.contents(atPath: a.path) else { throw fail(HostError(.failed, "cannot read \(a.path)"), g) }
            FileHandle.standardOutput.write(d)
        }
    }
}
