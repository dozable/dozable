# Public builds, usage statistics, updates and the release

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Scripts/helper-README.md`, `Scripts/helper-smoke.sh` (`make test-cli-helper`), `Sources/DozableCLI/HelperBuild.swift`, `Guest/kernel/` | 675: the helper build's README, its smoke, what it answers for the commands it leaves out, the pinned kernel's provenance and source offer |
| `Scripts/release.sh` (`make release`), `Makefile.config.example`; `ReleaseStamp` in `Sources/DozableCLI/DozableCommand.swift`; `HostUpgradeCheck` in `GroupCommands.swift`; `HostCore.programGone`; `Tests/DozableCLITests/ReleaseTests.swift` | the Homebrew artefact (signed; Developer ID + notarised when configured), the version stamp, `doz host upgrade-check`, the refusal when an upgrade removed a running host's keg |
| `Sources/DozableHost/Usage.swift`; `Sources/DozableCLI/UsageCommands.swift`; `Sources/doz/DozableMain.swift` | anonymous usage statistics and the sign-up — the open half: the closed list, the switches, the local record, `doz telemetry`, `doz signup`, the hook; the bridge to the official builds' closed package (`#if DOZ_CLOUD`) |

## Public builds — `BuildFlavor`

- **`make release` builds the PUBLIC flavor by default** (`PUBLIC=1` → `-DDOZ_PUBLIC_BUILD`; `PUBLIC=0` only for a private
  rc, which then needs `SOUND_KERNEL=<file>` or `NO_SOUND_KERNEL=1`). A public build has NO Dozable's own ChatGPT sign-in
  (it uses Codex's public client id — Codex's to use): `doz account add --chatgpt`, `onboard --openai-account chatgpt`,
  the create preflight and the dashboard never offer it, the host refuses `account-add` of kind `chatgpt`, and a
  ChatGPT account an earlier build stored is KEPT but never used (`unsupported` in `account ls`; every request says
  why — `ChatGPTSession.unsupported`). Codex keeps `mac` (the Mac's own Codex login) and OpenAI API keys. And NO sound
  kernel: `--audio` is refused with `BuildFlavor.audioMissing`. `release.sh` proves the flavor on the packed binary.
- Every decision takes a `BuildFlavor` (`HostCore.setBuildFlavor`, `OpenAIChoices`); a real process can be told with
  the TEST seam `DOZ_TEST_PUBLIC_BUILD=1|0`. `BuildFlavorTests` runs both modes in one `swift test`.

## The helper build — `FLAVOUR=helper` (675)

- **What**: the doz an app carries inside its bundle and drives over host.sock (SandboxLab; Deckosaurus next) —
  `make release FLAVOUR=helper` → `dist/doz-V-macos-arm64-helper.tar.gz` (+ `.sha256`, + `.dSYM.zip`), beside the CLI
  release of the same version. The user-facing page is `docs/manual/33-bundling-doz-in-an-app.md` (the layout contract,
  the rules for an app); the tarball's own `README.md` is `Scripts/helper-README.md`.
- **How it is made**: `DOZ_HELPER_BUILD=1` in the environment of `swift build` (Package.swift reads it, like
  `DOZ_CLOUD_PACKAGE`): it defines `DOZ_HELPER_BUILD` in DozableHost, DozableCLI and doz, and — unless `DOZ_HELPER_WEB=1`
  (the one switch to a helper WITH the dashboard) — drops DozableWeb from DozableCLI's dependencies and defines
  `DOZ_NO_WEB`, so neither the dashboard's code nor its bundle is built. `release.sh` builds it in its own scratch folder,
  `.build-helper/` (the flavours never share build products or a stale bundle), and passes `DOZ_HELPER_BUILD=0` to a CLI
  release explicitly.
- **What it leaves out, at compile time** (`Sources/DozableCLI/HelperBuild.swift` answers each name: "not in this
  build", exit 1): `doz ui`, `doz serve` (UICommand.swift, ServeCommand.swift under `#if !DOZ_NO_WEB`), the setup wizards
  `doz onboard`, `doz init` and `doz try` (OnboardCommands' flow, InitCommand, TryCommand, QuickMake, RulesStep under
  `#if !DOZ_HELPER_BUILD`). DozableTUI stays: `GlobalOptions` and every command's output use it (Foundation + Darwin, small).
- **What it never does: update itself.** `BuildFlavor.isHelper` (compiled, or the TEST seam `DOZ_TEST_HELPER_BUILD=1|0`)
  or a `RELEASE` that starts with `helper` → `InstallMethod.helper(app:)` (the `.app` it sits in): `disabledReason` says
  `BuildFlavor.helperUpdates` FIRST, whatever the settings, even for a manual check — so no feed is ever asked;
  `doz upgrade` refuses before anything ("this doz belongs to APP; APP updates it").
- **It sends no usage statistics** (owner, 2026-11-04): Package.swift never adds the closed package to a
  `DOZ_HELPER_BUILD=1` build, `release.sh` ignores `DOZ_CLOUD_PACKAGE` for `FLAVOUR=helper` and checks the packed helper
  says `"official": false`, and `UsageSwitches.decide` is off for `InstallMethod.helper` whatever the setting or flag
  (`doz telemetry show` says it is the helper build). The app that bundles it decides what it sends. No `doz signup` either.
- **It says what it is**: `HostStatus.flavour` (`cli` | `helper`, `BuildFlavor.flavourName`) in every ping /
  `host status`; nil from a host older than 0.37.41. Everything else about the host and the protocol is the CLI's.
- **Checked**: `release.sh` (the dashboard refused, `doz upgrade` refused, no DozableWeb bundle, README, no `bin/`) and
  `make test-cli-helper` (`Scripts/helper-smoke.sh`: the tarball copied whole into a fake `.app`, an EMPTY store, a lab VM
  booted from the kernel the helper carries — no download), which CI runs on the VM runner.

## Both flavours: stripped, with the kernel inside (675)

- **Stripped before signing** (`dsymutil` first, then `strip`; the dSYM's UUID must equal the stripped binary's): the
  symbols go to `dist/<name>.dSYM.zip`, published beside the tarball. An app must never strip or re-sign the helper.
- **The pinned kernel** (`KernelArtifact.recommended`) is in BOTH tarballs at `libexec/doz/kernels/vmlinux-6.18.15-186`,
  with `libexec/doz/licences/kernel/` (`Guest/kernel/PROVENANCE.md` — the written GPL-2.0 source offer —, `kernel.config`,
  kata's patch, `extract-config.py`). `release.sh` takes it from `KERNEL_FILE`, else `$DOZ_KERNEL_CACHE` (the Makefile's
  `KERNEL_CACHE`), else `~/Library/Caches/DozableKit/kernels` (filled once by `make kernel` when missing), and refuses any
  file that is not the pin. `KernelProvider` takes it as its FIRST seed (`bundledCandidates`: `kernels/` beside the
  resolved executable) — after the store's cache, before Apple's `container` copy and the download (the reason is in
  `KernelProvider`'s doc comment: the store never depends on the program's folder).

## Anonymous usage statistics and the sign-up — the open half

- **This repository holds the open half ONLY**: `Sources/DozableHost/Usage.swift` decides WHAT may be sent and WHETHER;
  the official builds' closed package (statistics sender + sign-up client, private, Foundation-only) only SENDS what
  it is handed. Never put the sender, an endpoint, a key or any closed code here. It joins a build only through
  `DOZ_CLOUD_PACKAGE` (Package.swift adds the dependency and defines `DOZ_CLOUD`; `Sources/doz/DozableMain.swift` calls
  `Usage.install(send:flush:signup:)` under `#if DOZ_CLOUD` — `canImport` alone is wrong: a module left in `.build` by
  an earlier official build makes it true in a build that does not link it). The audit allows `DozableCloud` in that
  file only. Without it (`make cli`, `make test`, CI, forks) `Usage.isOfficial` is false: nothing is recorded or sent.
- **The closed list** (`UsageSchema`): messages `installed`, `upgraded`, `daily`; every key in `UsageSchema.keys`/`nested`,
  every value a count, an ASCII range (`<=8`, `9-11`, `5-30m`), a time rounded to 50 ms (≤ 1 h, p50 ≤ p90) or a word of
  Dozable's own vocabulary (command names from the CLI's own tree — `UsageCommandName`, never an argument; agent ids;
  base CATALOGUE ids — a Dockerfile base is `dockerfile`, never its `df-<hash>` (a hash of the user's path), a
  template is not counted; network presets). `UsageSchema.problems` is the receiving side's validator ported, and
  `UsageRecorder.handOver` drops any message it does not accept. A new field is a schema change on BOTH sides and in
  the privacy policy — never just a new key here.
- **Nothing private is collected for it**: the day's numbers come from what the host already records (`metrics.sqlite`
  action rows — phases with their times, creates, removals, preparations; the network table's minutes; the store's
  sandboxes, restore points, workspace rule files, permissions, the LAN option's devices; `onboarded.json`) and the commands'
  own counts, computed on the Mac (`UsageStoreFacts`, `UsageTimeline`, `UsageDailyBuilder` — pure, tested on a fixed
  history). What the host did not record before, it now writes to the SAME local metrics, as times only: rows `attach`,
  `exec` (activity), `agent status` / `agent working` (612's status; working time from when `working` began), the create
  row's detail `account` (the KIND: mac, api-key, setup-token, none — never a name), and a failed preparation's
  `failedStep` (`PreparationStepID`: the metrics' fixed step keys, a recipe's bake step only as `bake-step`). The page sends
  `X-Doz-Display: standalone|browser` with its page-load renewal; only `standalone` is recorded (`app`), only while on.
- **How the time block reads**: a running or asleep stretch is counted ONCE, on the day it ends, by its whole length (a
  host crash ends one when the next host notices; a stretch still open is counted when it ends); `running_total` is the
  running time within the day; `removed_age` is from the sandbox's create row; `idle_running_8h` counts sandboxes with a gap
  of 8 h or more between activity (attach, exec, a session opened or restarted, agent status, network use) inside a running
  stretch, ending that day — an attach held open for hours counts only at its start. `first_sandbox` and
  `time_to_first_session` (from `firstSeen` in usage.json) are each sent once.
- **The off switches, checked before anything is recorded** (`UsageSwitches.decide`): not official → off; a guarded test
  run → off; a development build (`InstallMethod.development`) → off; `DO_NOT_TRACK` (anything but empty/0/false) →
  off, even against the flag; else the setting `telemetry.send_anonymous_usage_stats` (flag > `$DOZ_SEND_ANONYMOUS_USAGE_STATS`
  > file > default true). Turned off for good (setting/env/DNT), the recorded days are forgotten.
- **What is kept**: `<settings dir>/usage-id` (random lower-case UUID, `doz telemetry reset`) and `usage.json` (today's
  counts, a closed day, the last version, the notice) under a `flock`. **When**: `DozableEntry` counts the command BEFORE
  it runs (`UsageHook.before`) and after it records a failure's exit code and hands over what is due — `installed` /
  `upgraded` once per version, the `daily` of a closed day (≤ 7 days old) on the first command of a later day — then
  `flush(1 s)` only when something was handed over. Never for `telemetry`, help/`--version`, internal re-launches
  (`--launched`, `--launch-detached`, `--restarted`) or `host upgrade-check`. The one-line notice: once, official and
  on, stderr on a terminal, never `--json`/`-q`.
- **The setup's Usage statistics step** (`UsageStatsStep` — ONE model for both): `doz onboard` (after the preparation,
  just before Stay in touch; `UsageStatsPrompt` decides, pure) and the wizard's `WIZ.usage` (from `sessionInfo.usageStats`,
  the projection `WebUsageStats`; saved through `POST /api/v1/settings`). Official builds only; default on; an answer is
  written ONLY when it changes `telemetry.send_anonymous_usage_stats` (the Access rule — `--yes`, no terminal, or Yes on a
  default install write nothing; `--usage-stats on|off` answers it); DO_NOT_TRACK / the variable / doz ui's flag deciding
  is said, never asked. Shown, it marks the one-line notice shown (`UsageStatsPrompt.markNoticeShown`) so it never repeats.
- **The sign-up** (`SignupRequest`: email + `release-news`/`early-access`/`tips` + source; the Worker reads an older build's `support` as `tips`): `doz signup`, `doz onboard`'s
  Stay in touch (its LAST step, terminal only, default No; `--yes` skips), the wizard's Stay in touch step → `POST /api/v1/signup` (strict
  `{email, interests}`, CSRF; the source is the server's; a failure is ONE fixed message; 404 `signup-unavailable` in an
  open build, whose page hides the step and shows `sessionInfo.signupPage`). The email is never logged, echoed or kept;
  `SignupRequest`'s description is redacted. Independent of the statistics switch and never linked to them.
- **Release**: `make release` passes `DOZ_CLOUD_PACKAGE`/`DOZ_CLOUD_REF` from `Makefile.config` (never exported to other
  targets); `release.sh` refuses a PUBLIC release without it (TEST_BUILD=1 excepted), checks the packed binary's
  `doz telemetry show --json` says `"official": true` (scratch folders; looking never sends), restores
  `Package.resolved` if a URL pinned the package, and writes `RELEASE` = `public+cloud` (`publish.sh` accepts `public*`).
- **Tests**: `UsageTests` (the encoder vs the list byte for byte, refusals, buckets, the daily from metrics rows, the
  switches, once a day/version, the notice, the setup step, a FAKE installed sender), `WebSignupTests`, `WebUsageStatsTests`. A fake closed package for an
  end-to-end look lives in the workspace's probes (`DOZ_CLOUD_PACKAGE=<it> swift build --product doz`); never point a
  test at the live endpoint.

## Updates: the signed feed, channels, `doz upgrade`

- **ONE feed, compiled in**: `https://updates.dozable.com/v1/feed.json` since 0.37.2 — every earlier doz asks
  `https://updates.dozersandbox.com/v1/feed.json`, a PERMANENT 301 to it (a Cloudflare redirect rule on dozersandbox.com:
  never remove it, and never let dozersandbox.com lapse); `publish.sh` writes the Pages `CNAME` from this constant
  (`Distribution.feedURL` in
  `Sources/DozableHost/Updates.swift` — with `tap`, `repository`, `teamID` and `updatePublicKey`, the ONE place these
  names live; the scripts read them with `sed`, and `docs-drift-check` fails on a doc naming another tap/repo). `/v1/`
  is the FORMAT — a new format is `/v2/` beside it, never a change to v1. All three channels in one file, each entry
  tagged; stable ⊂ beta ⊂ canary.
- **Each entry is signed with DOZABLE's own Ed25519 key** (never Deckosaurus's): the private key lives ONLY in the
  publishing Mac's login keychain (`make doz-update-keys` makes it, once, after asking; `Scripts/update-key.swift`;
  through `security -i` stdin) + an offline backup. Never rotate it — every installed doz trusts the public
  key compiled in. The signed message (`UpdateSignature.message`, and the script's twin) covers version, build, the
  archive's FILE NAME, sha256 and size — NOT the channel (a promotion needs no key). An entry that does not verify is
  dropped; a feed that is not one is ignored; each said ONCE (`UpdateState.reportedProblem`). Tests use a throwaway key.
- **The client** (`UpdateChecker`): at most daily (a failed check retried after an hour) + forced when `doz ui`
  starts (and daily while it runs); conditional (If-None-Match/If-Modified-Since); offline silent; state in
  `<settings dir>/updates.json`. Never a downgrade (`SemVer`; `WebVersion` delegates to it). Never in a guarded test
  run without its own feed (`DOZ_TEST_UPDATE_FEED`), never for a development build (`InstallMethod`: a Homebrew keg
  by its Cellar path; a tarball install by `libexec/doz/{VERSION,RELEASE}` — `release.sh` writes `RELEASE`,
  `make install-cli` does not). Settings `updates.mode` (off | notify | auto) and `updates.channel` (a Homebrew
  install's formula decides while it is unset).
- **After a command** (`DozableEntry` in `UpdateCommands.swift` is `doz`'s main: ArgumentParser's parse-and-run, then
  `UpdateHook.afterCommand`): only on a terminal (stdout AND stderr), never `--json`/`-q`, never for
  update/host/serve/uninstall/config; one stderr line per version per day. `auto` installs only when
  `UpdateInstaller.busyReason` is nil (no host, or one with no live sandbox and no other client) — else the line says
  why not. Homebrew: `brew upgrade <formula>`; a tarball: download → size + sha256 of the SIGNED entry → unpack →
  `codesign --verify --strict` + team `KJ8QMLWB97` → its `--version` → ONE `renamex_np(RENAME_SWAP)` of `libexec/doz`,
  the previous kept as `libexec/doz.previous` (a running host keeps its inode — the 591 rule). Then "Updated to X —
  restart to apply: doz host restart" (`doz host restart` = stop with progress + start). The dashboard's banner reads
  `UpdateChecker.remembered` (no network per page) via `WebSessionInfo.update`.
- **`doz upgrade [--check] [--channel X]`**: `--check` exits 10 when one is available; `--channel` writes the setting
  and, for Homebrew, switches formulas (`brew uninstall` then `brew install <tap>/<formula>`, reinstalling the old one
  if that fails) — refused when the new channel's newest is not newer (never a downgrade).
- **Publishing** (`make publish VERSION= NOTES= CHANNEL=canary`, `make promote BUILD= CHANNEL=`; `Scripts/publish.sh`,
  `promote.sh`, `feed.py` — Deckosaurus's appcast design as JSON): per-build fragments `v1/items/build-N.json` → the
  generated, deterministic `v1/feed.json` + `v1/notes/V.html` in `UPDATES_DIR`; the three formulas (each channel's
  newest; `Scripts/homebrew/doz.rb.tmpl`, conflicting with each other) in `TAP_DIR`. Idempotent; a published version
  is never re-cut; promote never rebuilds and only widens; nothing is pushed without `PUSH=1`; the GitHub release
  command is printed, never run. A publish refuses a key that doz does not trust. Seams: `TEST_PUBLISH`,
  `UPDATE_KEY_FILE`, `UPDATE_PUBLIC_KEY`, `ARCHIVE_BASE`; client `DOZ_TEST_UPDATE_{FEED,KEY,EXECUTABLE,TTY,ALLOW_ADHOC}`,
  `DOZ_TEST_BREW`.
- **Channels in practice**: stable (`doz`) is the published, recommended channel; development happens on canary. The
  workspace's `Scripts/doz-rc` (an rc) and `Scripts/ship` (a shipped version, a GitHub PRE-release) both publish to
  CANARY only (`make publish CHANNEL=canary PUSH=1`); stable moves only when the owner says so: `make promote
  VERSION=… CHANNEL=stable PUSH=1`, then `gh release edit vX.Y.Z --prerelease=false --latest`. (`PUSH=1` refuses
  UPDATES_DIR/TAP_DIR that are not git checkouts with an origin.) Before the unveil, releases went to a private
  prelaunch repo + tap (now archived; `DOZ_PUBLIC=0` in `_ship_common.dozer_profile` still names that era).
- **Tests**: `UpdatesTests` (unit), `make test-updates` (the real binary: release-shaped tarballs → publish → promote →
  a local feed server → check/notify/silence/off/channels/downgrade/tampered/auto swap/fake brew).

## The release and Homebrew

- **`make release VERSION=X.Y.Z`** (`Scripts/release.sh`) is the ONE way the artefact is made:
  release build → `dist/stage/doz-X.Y.Z/{bin/doz → ../libexec/doz/doz, libexec/doz/{doz, VERSION, RELEASE,
  DozableKit_*.bundle, kernels/, licences/}}` → stripped (dSYM zip beside) → signed → `dist/doz-X.Y.Z-macos-arm64.tar.gz`
  + `.sha256` (`FLAVOUR=helper`: the helper build, above). It checks the
  signature (`--verify --strict`), the virtualization entitlement, and that the packed `doz --version`
  says X.Y.Z. `Scripts/ship` (the workspace) runs it after tagging, then runs it again with `FLAVOUR=helper`, and
  attaches all six files to the tag's GitHub Release: each tarball, its `.sha256` and its `.dSYM.zip`. The release's
  notes point app authors at the helper's page. A missing file stops it before anything is uploaded; the feed and the
  formulas name only the CLI tarball (`make publish`).
- **The version comes from the tag, never a hand-edited constant**: the tarball carries
  `libexec/doz/VERSION`; `DozableCommand.version` reads it beside the resolved executable
  (`ReleaseStamp`) and falls back to `builtVersion` for `make cli` / `install-cli` / tests.
- **Signing**: a Developer ID (`SIGN_IDENTITY`, and `NOTARY_PROFILE` for `notarytool`) comes ONLY
  from the gitignored `Makefile.config` (`Makefile.config.example`); then `--options runtime
  --timestamp` (the entitlements work under the hardened runtime — measured, cold boot and wake), every
  Mach-O in the bundles signed too (the guest binaries are Linux ELF: left alone), notarised, checked
  with `spctl`. A bare CLI cannot be stapled. Never a password in a file, never `notarytool` without a
  profile. `DRY_RUN=1` prints every command. 611: a PUBLIC release refuses to build unsigned or
  unnotarised (`TEST_BUILD=1` is a local test build, never published); a preflight asks the keychain for
  the identity and the profile authenticates BEFORE the build; the signed binary is checked for the
  authority, the team id, the hardened-runtime flag, a secure timestamp and both entitlements
  (virtualization, audio-input); notarisation must answer `Accepted` (else its log is fetched) and Apple's ticket service must hold a ticket for
  the binary's CDHash (`Scripts/notary-ticket.sh` — NOT `spctl`: a bare CLI cannot be stapled, and spctl answers from a
  stapled ticket or Gatekeeper's local cache, "Unnotarized Developer ID" for a freshly notarised tool — 0.31.0); and the TARBALL is unpacked afresh and checked (`codesign --verify --strict`,
  `doz --version`). Never edit sources while `make release` builds (SwiftPM stops: "modified during the build").
- **Resources are found beside the RESOLVED executable** (`DeckholdBinary.candidateBundleDirectories`,
  `WebAssets`, `HostLauncher.executablePath`): the Homebrew keg (`Cellar/doz/V/libexec/doz`, reached
  through `bin/doz` links) works with no path hard-coded — keep it that way.
- **An upgrade removes the previous keg under a running host** (`brew upgrade` runs `brew cleanup`):
  the host keeps its open program and its VMs, but a boot would fail on a missing guest binary. So
  `HostCore.programGone()` (the executable removed, or deckhold/doznet not found) refuses every
  `bootOps` op and a wake-by-use with "this host's program … is gone — `doz host stop`, then retry";
  `host status`/`doctor` say so; the idle loop exits it once nothing is live. `doz host upgrade-check`
  (the formula's post-install) says when a host of another build runs — via the socket, else the pid
  file + `proc_pidpath` (Homebrew's post-install sandbox) — never starts/stops one, always exits 0.
- **`doz uninstall` never removes a Homebrew keg** (`Uninstall.homebrewKeg` — any channel's formula: doz,
  doz-beta, doz-canary): it removes the store and settings and names `brew uninstall <formula>`.
- **The tap** (`Distribution.tap`, `dozable/tap` → the repository `dozable/homebrew-tap`; moved from
  `dozer-sandbox/homebrew-tap` in 0.36.1, and a Mac that tapped the old name keeps it — `doz upgrade` uses whichever
  is tapped, `UpdateInstaller.installedTap`, the old names in `Distribution.previousTaps`): one
  formula per channel, `Formula/doz.rb`, `doz-beta.rb`, `doz-canary.rb`, GENERATED by `make publish`/`promote`
  from `Scripts/homebrew/doz.rb.tmpl` (arm64, macOS 26+, conflicting with each other, `post_install_steps` →
  `host upgrade-check`, a `test do` that runs `--version` and `doctor --json` in a scratch store).
