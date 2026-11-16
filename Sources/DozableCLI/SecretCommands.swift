import DozableHost
import DozableKit
import Foundation

// 692: `--secret VAR,src=PATH,to=HOST:PORT[,header=NAME][,file=FILEVAR]` on `doz create`, `doz run NAME` and `doz run @mac`
// (fenced). The value is read HERE, from the file only (never argv, never -e), checked, and sent to the daemon once.

/// The help every command taking `--secret` shows (one text — the example names a message server on this Mac).
let secretHelp = "A secret for a service, held by Dozable: VAR,src=PATH,to=HOST:PORT[,header=NAME][,file=FILEVAR]. "
    + "The value is read from PATH (yours alone: chmod go-rwx; one line); the session sees only a placeholder in VAR (and, with "
    + "file=, in a file named by FILEVAR), which Dozable's proxy swaps for the secret on requests to exactly HOST:PORT — as "
    + "Authorization: Bearer, or the header you name. Over plain HTTP only to this Mac's ports (host.dozable.internal) and "
    + "Tailscale addresses (network.placeholders_plain_http). Repeatable, at most 4. A message server on this Mac: "
    + "--host-port 8780 --secret SERVER_TOKEN,src=~/.config/token,to=host.dozable.internal:8780,file=SERVER_TOKEN_FILE"

/// Every `--secret` value parsed, checked together and its file read (a relative PATH is from where doz runs). Throws a
/// plain `HostError` — never quoting a file's content.
func readLaunchSecrets(_ words: [String], cwd: String = FileManager.default.currentDirectoryPath) throws -> [LaunchSecretGrant] {
    guard !words.isEmpty else { return [] }
    var specs: [LaunchSecrets.Spec] = []
    for w in words {
        var s = try LaunchSecrets.parse(w)
        if !s.source.hasPrefix("/") { s.source = URL(fileURLWithPath: s.source, relativeTo: URL(fileURLWithPath: cwd, isDirectory: true)).standardizedFileURL.path }
        specs.append(s)
    }
    try LaunchSecrets.check(specs.map { ($0.variable, $0.fileVariable) })
    return try specs.map { s in
        let (value, real) = try LaunchSecrets.read(s.source, variable: s.variable)
        let record = LaunchSecret(variable: s.variable, fileVariable: s.fileVariable, host: s.host, port: s.port, header: s.header,
                                  bearer: s.bearer, fingerprint: CredentialFingerprint.of(value))
        return LaunchSecretGrant(secret: record, value: value, source: real)
    }
}
