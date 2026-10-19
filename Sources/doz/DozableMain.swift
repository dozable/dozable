// doz — the DozableKit command-line tool (585). Everything lives in the DozableCLI target (so the unit tests can reach
// it); this only runs it. 611: through `DozableEntry` — ArgumentParser's parse-and-run, then the update check.
import DozableCLI
import DozableHost
#if DOZ_CLOUD
// Official builds only: the closed package that sends the anonymous usage statistics and the sign-up
// (Package.swift adds it, and defines DOZ_CLOUD, only when DOZ_CLOUD_PACKAGE names it). It is handed finished messages of the closed list in
// Sources/DozableHost/Usage.swift — the open code decides what is sent and whether. A build from this repository
// has no such package: nothing is installed here, and nothing is ever sent.
import DozableCloud
#endif

@main
struct DozableMain {
    static func main() async {
        #if DOZ_CLOUD
        Usage.install(send: { DozableCloud.send($0) },
                      flush: { DozableCloud.flush($0) },
                      signup: { r in
                          let answer = try await DozableCloud.signup(email: r.email, interests: r.interests, source: r.source)
                          return SignupResult(status: answer.status)
                      })
        #endif
        await DozableEntry.main()
    }
}
