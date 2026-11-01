# CLAUDE.md

The engineering guide to Dozable — for contributors and for coding agents alike: what each part is, where
the code lives, the rules that each cost a bug to learn (keep them, and their tests), and how a change is verified.
The user manual is `docs/manual/`; the developer view of the engine is `docs/DOZABLEKIT.md`.

**Reading the history in this repository.** Dozable is developed in a private workspace and released from here. Code
comments and a few notes below cite the feature that introduced something by its number (`591`, `599i`) and the
design notes or probes it came from (`changes/591-*/…`, `probes/…`) — those live in that workspace, not here; the
rule they explain is always stated where it is cited. "SandboxLab" is the earlier prototype app the engine grew out
of; "DeckStack" and "Deckosaurus" are sibling projects some techniques were taken from (never a dependency).

## This is an APP — the `doz` product

- **It ships as an app:** its own `VERSION` (CI's `version-check` enforces VERSION strictly greater than `main`'s);
  a release tags `v<VERSION>` and attaches `doz-<VERSION>-macos-arm64.tar.gz` (`make release`), and the update feed
  and the Homebrew formulas follow (`make publish` / `make promote` — see "Updates").
- **The Swift package is named `DozableKit`** (products `DozableKit` and `doz`). A later version moves the engine (the
  `DozableKit` target, `Guest/`, the in-VM helpers) into a library of its own; until then nothing else consumes it.
- `make audit-resolved` exists for the release gate: this repo pins no sibling library.

## Dependencies

| Product | Targets | Depends on |
|---|---|---|
| `DozableKit` | `DozableKit` (+ resources `deckhold`, `doznet`, `dozview`, `tmux`); test-only C target `DozMatch` (`Guest/dozview/match`) | `apple/containerization` **exact** `0.47.0`: `Containerization`, `ContainerizationArchive` (the kernel tarball), `ContainerizationExtras`, `ContainerizationOCI`, `ContainerizationOS`; since 580 `swift-nio` (`NIOCore`, `NIOEmbedded`; 583 `NIOPosix`), `swift-nio-ssl` (`NIOSSL`), `swift-certificates` (`X509`), `swift-asn1` — apple/* packages containerization already resolves (README "Dependencies") |
| `doz` (executable, 585) | `doz` → `DozableCLI` (commands) → `DozableHost` (the host + its client); 637: `DozableCLI` → `DozableTUI` (terminal components, the colour switch — Foundation + Darwin only, audit) | `DozableKit`; `swift-argument-parser` (`ArgumentParser`) in `DozableCLI`/`doz` ONLY; the system `SQLite3` in `DozableHost` (metrics); `jpsim/Yams` **exact** `6.2.2` in `DozableCLI` ONLY (`doz_project.yaml` — the audit enforces the pin and the confinement); 667: the system's `AVFoundation` in `DozableHost/Microphone.swift` ONLY (the microphone's permission — never a capture; audit) |
| — (not a product) | `DozableWeb` — `doz ui`'s server and page (645: one server — this Mac's browser and, with the LAN option, the network's) | `DozableHost`; `swift-nio` `NIOCore`/`NIOPosix`/**`NIOHTTP1`**/**`NIOWebSocket`** (both ONLY here — the audit enforces it); the system's **`dnssd`** (Bonjour) in `WebBonjour.swift` ONLY (audit); resource `Resources/Web` (generated, committed). `DozableCLI`'s `UICommand.swift` alone imports `CoreServices` (LaunchServices opens the browser) |
| — (not a product) | `doz-vmtest` — the entitled VM test host | `DozableKit`, `DozableHost` (the `cli` mode decodes `--json` with its types) |

The Containerization pin is EXACT on purpose: the sleep design leans on its internals' shape —
`LinuxContainer.withVirtualMachineInstance` handing out a `VZVirtualMachineInstance`, the
`VZInstanceExtension` hook, the public `VirtualMachineManager` / `VirtualMachineAgent` protocols,
and how `LinuxContainer.create()/start()/stop()` call them. A bump is a deliberate re-verification:
`make test-vm` green twice.

## Where the code lives

One row per area; each area's doc starts with the full table of its files.

| Area | Where | Detail |
|---|---|---|
| The engine and the host | `Sources/DozableKit/` (Sandbox, Phase, VirtualMachine, disks, restore points, kernel), `Guest/deckhold/`, `Sources/DozableHost/` (HostCore, HostServer, HostClient, Settings), `Sources/DozableCLI/`, `Sources/doz-vmtest/` | [engine.md](docs/engineering/engine.md) |
| The network | `SubnetPool`, `NetworkPolicy`, `EgressProxy`, `Credentials`, `SandboxCA`, `Guest/doznet/`, `PortForwarding`, `MacModelServer` | [network.md](docs/engineering/network.md) |
| Images, bases, agents, resources | `ImageSpec`, `ImageBaker`, `BaseCatalogue`, `AgentPermissions`, `Resources.swift`, `ImageTree` | [images-and-bases.md](docs/engineering/images-and-bases.md) |
| Accounts, GitHub, Access | `ClaudeLogin`, `Accounts`, `LoginWatcher`, `HostCore+Accounts` | [github-and-access.md](docs/engineering/github-and-access.md) |
| Codex | `OpenAIAccess`, `ChatGPTAccounts`, `ChatGPTSignIn` | [codex.md](docs/engineering/codex.md) |
| Agent recipes, key providers, the catalogue | `RecipeCatalogue`, `RecipeOrigin`, `RecipeCommands`, `Scripts/publish-recipes.sh` | [recipes.md](docs/engineering/recipes.md) |
| `doz ui` — the web layer | `Sources/DozableWeb/`, `WebSource/` → `Resources/Web/`, `Tests/DozableWebTests/` | [web.md](docs/engineering/web.md) |
| The LAN option | `Sources/DozableWeb/WebServe*.swift`, `WebExposure`, `WebBonjour` | [lan.md](docs/engineering/lan.md) |
| The terminal | `Sources/DozableTUI/` | [terminal-tui.md](docs/engineering/terminal-tui.md) |
| Onboarding, projects | `Preparations`, `Onboarding`, `AgentPrompt`, `OnboardCommands`, `ProjectFile` | [onboarding.md](docs/engineering/onboarding.md) |
| Sessions | `SavedScreens`, `BootLogs`, `SessionStatus`, `ScreenGrid`, the attach relay's bridges | [sessions.md](docs/engineering/sessions.md) |
| Builds, statistics, updates, release | `Usage.swift`, `Updates.swift`, `Scripts/release.sh` | [updates-and-release.md](docs/engineering/updates-and-release.md) |
| Workspace rules | `Guest/dozview/`, `DockerIgnore`, `WorkspaceRules`, `WorkspaceView` | [workspace-rules.md](docs/engineering/workspace-rules.md) |
| Tools layer, tmux, dotfiles | `Guest/tmux/`, `Dotfiles.swift` | [tools-and-dotfiles.md](docs/engineering/tools-and-dotfiles.md) |
| Files | `WorkspaceFileList`, `WorkspaceFileChange`, `FileWatch`, `EditorApps`, `WebFiles` | [files.md](docs/engineering/files.md) |
| Sound | `Audio.swift`, `DozSound.swift`, `MacAudio`, `Microphone`, `Guest/sound-kernel/` | [sound.md](docs/engineering/sound.md) |

## Rules that each cost a bug to learn (keep them, and keep their tests)

- **Sessions start WITHOUT `sh -c`.** BusyBox ash leaks an ignored SIGQUIT into what it execs, and a
  program cannot trap a signal ignored on entry (576: the screensaver's `m` menu). `GuestCommand.serve`
  builds argv; deckhold additionally resets every signal to default before exec. Utility execs
  (`exec(["sh","-c",…])`) may use a shell — never a session.
- **Stop keeps the root disk**: Stop shuts the VM down and persists the phase as `off`; the next Start cold-boots
  the SAME disk and clones the prepared disk only when none exists. `resetToImage()` discards the
  root disk; `delete()` removes the sandbox's whole directory. No Stop leaves a snapshot, and a
  snapshot found beside a kept disk on a cold Start is deleted — never restored onto a disk that
  has moved on.
- **One vmnet network per `Sandbox`, and never vmnet's default subnet beside another process.** Each
  Start used to create a new vmnet network (after a handful the guest had no route out); it is now
  created once and reused. Two processes that both take the default can get the same subnet and the
  same guest addresses — the NAT then silently drops one (the gateway still answers ping). Since 583
  the library never takes the default: with no `SandboxSpec.subnet` a NAT sandbox (and a NAT bake)
  gets a free /24 from 192.168.100–199 (`SubnetPool`: none a host interface is on, none this process
  holds, tried from a random start); an explicit subnet stays an override. The test hosts still pin
  192.168.201/202.0/24. `hardening subnets` is the test.
- **Every sandbox VM uses the ONE shared event-loop group** (`SharedEventLoop.group`, 583). Left to
  itself `VZVirtualMachineInstance` makes an 8-thread group and shuts it down only in its own `stop()`,
  which Hibernate never calls — each VM instance a host made kept 8 threads + 8 kqueues forever (582;
  thread cap 6,144). `hardening leak` is the regression test (threads, fds, footprint flat).
- **Quit lets a just-started program settle**. `prepareForExit(settle:)` waits out the rest of 3 s
  since the last `openSession` before it hibernates (580: Claude Code hibernated within ~1 s of its
  launch exited after the wake in 2 of ~7 runs). `hardening settle` is the test.
- **Stop decides from the phase it was CALLED in** (`perform()` reads `phase` before going busy).
- **Every VM has a memory balloon; a snapshot is never taken with it inflated**. A device is a
  VM input: `PinnedIdentity.memoryBalloon` comes from `PersistedSandbox.memoryBalloon` on a restore
  (nil = an older build's VM — restore it WITHOUT one) and is true on every cold boot. `wake()`
  inflates it over free guest pages — 651: AFTER the wake is reported done, the last of its background
  steps (see "A wake is done when the guest runs") — and it STAYS inflated (VZ charges the pages again on deflate —
  measured). `.restoreGuestMemory` runs before every pause-for-snapshot, and `saveSnapshot` deflates
  a paused one (resume → deflate → pause): a snapshot of an inflated balloon fails to restore
  (`VZErrorDomain 12 invalid argument`). Progress is read from the guest's `/proc/meminfo`
  `Balloon:` line — VZ offers DEFLATE_ON_OOM, so MemTotal never moves.
- **Stop is always graceful.** A paused VM is resumed and a VM on disk restored (silently — no phase
  event) and then `LinuxContainer.stop()` runs. Stopping at the VZ level instead leaves the package's
  vminitd gRPC clients unclosed, and deallocating one is a FATAL error
  (`Deinited NIOAsyncWriter without calling finish()`, seen in the 578 suite). Anything that could
  not be stopped through the package goes to `Graveyard` rather than being deallocated. Every exec
  is `delete()`d, including on error paths — deletion is what closes its client.
- **A wake's first guest calls are retried on a closed channel**. A restored guest resets its
  vsock transport as it resumes; a vminitd connection dialled in that moment can be closed under its
  first call (`unavailable: "The channel was closed"` — 582: 2 of 31 concurrent wakes; always
  `resyncClock`). `resyncClock` and `remountShares` are idempotent, so `retryingFirstGuestCall` retries
  them on a fresh connection. `hardening concurrent` (16 at once) is the regression test.
- **The snapshot is deleted the moment the VM runs again** (resume, wake, restore) and on stop.
- **Wake re-syncs the guest clock and re-mounts every share.** The re-mount lists the fresh virtio-fs
  root (READDIRPLUS) before binding: the "fresh" mount reuses the live superblock, and without the
  listing the bind picks up a stale dentry — the suite's SECOND wake lost `/work`.
- **A wake is done when the guest runs** (651, owner: "move them off the critical path"): `wake()` /
  `restoreAfterCrash()` return — the phase running, the host's answer sent — once the guest runs with its
  clock re-synced, its shares re-mounted (programs need them) and the snapshot deleted. The rest
  (`LifecyclePlanner.afterWake` / `afterAdoption`: `.applyGuestFixes` — the guest fixes, `refreshDeckhold`, the
  tools layer — then `.returnFreeMemory`) runs in `Sandbox.runAfterWake`, a task of the actor that OWNS the
  lifecycle gate the wake took (`perform` hands it over instead of releasing it), so every later lifecycle call,
  restore point, capture, rename and `prepareForExit` waits for it — never a snapshot mid-balloon or inflated. A
  waiting sleep/hibernate/stop/reset/delete/quit skips what is left at a step boundary (the next wake applies it
  again), a waiting pause only the balloon (`skippedWhenWaiting`). Best effort: a failure is a note, never a failed
  wake. `openSession` and the public `exec` wait for it (`afterWakeSettled()`) — open-session re-applies only the
  open-URL shim and (agent images) the sudo rule, not /etc/hosts, debconf, git, the SSH agent or this build's
  deckhold — and the host's open-session waits anyway (`refreshWorkspaceViews` takes the gate); an attach does
  not wait. The event stream ends it with `SandboxEvent.afterWakeDone` (never a client's event): the host's boot
  log keeps recording until then (`Managed.bootTail`, `BootRecorder.seal`) and is written after it — its time is
  the wake's to its end, the background steps one "after the wake, in the background" step. `LifecycleTests`.
- **Connections are identified by object, never by a file descriptor number,** and a closed
  connection never delivers or sends a byte (the 576 recycled-fd Stop bug).
- **Crash restore = identical VM + adoption.** The machine identifier and the NIC's MAC are pinned
  (`PinnedIdentity`), the vmnet subnet reused, and `AdoptingAgent` answers `LinuxContainer`'s
  guest SET-UP calls as already done while the restored guest is adopted.
- **The library owns its kernel.** Never read `~/Library/Application Support/com.apple.container`
  as a source of truth (the runners have no `container` CLI; that file is another tool's to change).
  A file there is used only as a SEED, and only when its sha256 equals the pin. A kernel change is a
  new `KernelArtifact` (URL + archive sha256 + member + kernel sha256) and `make test-vm` twice — a
  snapshot must be restored with the kernel it was taken under.
- **Restore points are disk-only APFS clones — never live forks**. A copy of a RUNNING
  VM is crash-consistent at best, so it is marked `needsFsck` and the next boot from it runs e2fsck
  first (`FsckHelper`) — journal or not. e2fsck runs on the image FILE over virtio-fs: a container's
  device cgroup refuses a raw block node even to a privileged exec.
- **A kept disk that was not cleanly unmounted is replayed or e2fsck'd before it cold-boots** (583,
  587). Hibernate stops the VM at the VZ level, so a discarded snapshot (`discardRestorableState`),
  a failed restore, a crash while running or a VZ-level stop fallback leaves a disk that was never
  unmounted. A JOURNALED disk (587's default, 16 MiB) is replayed by the kernel on mount — no mark,
  no e2fsck (`lineage journal`: 15/15 clean, ~380 ms). A journal-less one (`journalMiB: nil`, and
  every pre-587 disk) is marked and e2fsck'd (582: 12 of 15 such cold boots failed with `EXT4-fs
  error … doubly allocated`). `keptDiskNeedsFsck(_:snapshotPresent:journaled:)` decides from the
  disks' superblocks (`disksJournaled`); `hardening discard` pins the journal-less path.
- **The journal is a key input**: `ImageSpec.journalMiB` is in the bake key and the base key,
  `SandboxSpec.journalMiB` in the prepared-disk key (a journal-less one keeps its pre-587 key, and so
  does the e2fsck helper's). A record written before 587 decodes as `nil` = no journal — its disks
  have none. Never default a DECODED value to 16.
- **Hibernate and Stop sync the guest first** (`.syncGuest`, best effort): a discarded
  hibernation lost the last ~5 s of writes in every journal mode. It also records `df` usage for
  `DiskAccounting`'s fallback garbage.
- **Mount options are not VM inputs**: `discard` on the root and state disks goes to the guest's
  mount only (Containerization maps only `ro` into the VZ attachment), so a snapshot taken before 587
  restores unchanged (587 proved it with `lineage compat-wake`, retired in 592).
- **Children never depend on a parent's FILE**: a base, an image and a sandbox are APFS clones;
  deleting or re-deriving a parent never changes a child (`lineage children`). Maintenance
  (`reclaim`/`rederive`) touches only blocks ext4 marks free, refuses any disk that is not cleanly
  unmounted (its bitmaps would be stale), and `rederive` replaces the root disk only by an atomic
  rename after verifying the new one.
- **Metadata dates have fractional seconds** (`ImageBaker.encoder`): restore points taken within one
  second must sort in the order they were taken.
- **A proxied VM has NO NIC; the host proxy is the only way out**. The guest shim decides
  nothing. Every boot, crash restore and wake re-registers the proxy's vsock listener
  (`listenForEgress`) — the listener happened to survive a same-process wake in the probe, but a
  crash restore is a new VM.
- **A real key given to `openSession`/`exec` is moved into the vault** and replaced by a
  placeholder; keep it that way — "keys never enter the sandbox" rests on it.
- **This Mac's loopback is never a sandbox's** (660): a proxied sandbox's traffic leaves from the host process, so a
  connection the proxy makes to `127.0.0.1`/`localhost`/`::1` IS the Mac's — another sandbox's forwarded web port, a
  database, a local model server. `Wire.connectTCP` refuses a loopback or unspecified address whatever the policy (Open
  included; the tunnel and plain-HTTP paths answer 403 `loopbackRefusal` first), like 606's dashboard ports. The ONLY
  ways through: the proxy's guarded test seams (a fake upstream on 127.0.0.1) and `EgressProxy.macModelPort` — the one
  port a sandbox was made with (`SandboxConfig.localModelPort`, `--provider local --local-port N`), reached as
  `mac.dozable.internal:N` (the proxy's DNS answers a synthetic 198.18.255.254 and routes it; any other port of that
  name is refused; no port: NXDOMAIN). Never a policy rule (no preset or edit widens it). `MacModelServerTests`, the
  workspace's `probes/660-*/vm-proof.py`. Keep any new route to the Mac's own addresses behind the same refusal.
- **The agent has passwordless sudo by default**. The dev baseline
  installs `sudo` and KEEPS apt's package lists (~18 MiB, shared by APFS clones; `apt-get clean` only),
  and `apt-utils` FIRST (W24: otherwise every install says "debconf: delaying package configuration");
  the rule itself is never baked: `GuestCommand.agentSudoScript` writes `/etc/sudoers.d/doz-agent`
  (0440, root, `user ALL=(ALL) NOPASSWD:ALL`, put in place only after `/usr/sbin/visudo -cf` accepts it;
  absolute paths — a utility exec's PATH may lack sbin) or removes it — at every fresh boot
  (`prepareGuest`, from `Sandbox.agentSudo`), every wake (W34: `GuestCommand.guestFixes` — the live-safe
  part of `prepareGuest`: /etc/hosts, debconf Noninteractive, the open-URL shim, the time zone, the sudo
  rule — run as ONE root exec by `LifecycleStep.applyGuestFixes` after a wake from sleep, from
  hibernation and a restore after a host restart — 651: after the wake is reported done, in its background
  steps, which a session open waits for; never on a resume from Pause; best effort, a failure
  is noted; NOT the deckhold socket reset or the bind mounts) and every agent session start (`deliverAgentPrompt`), so a
  toggle needs no rebake. The value: `SandboxConfig.agentSudo` (`--[no-]agent-sudo`, `agent_sudo` in
  doz_project.yaml, synced by `doz up` through `agent-prompt`'s `agentSudo`/`clearAgentSudo`) else the
  setting `sandbox.agent_sudo` (read per request — `HostCore.agentSudo`). The facts block and skill say
  it (`sandbox.sudo`, `sudo.description`). **Security: root inside the VM must reach nothing the agent
  cannot** — the boundary is the VM (no NIC; the only way out is the proxy's vsock listener, where the
  policy is judged), the proxy/allow list and the absent credentials (the vault stays on the Mac).
  Root must never reach: the host's socket or the store (never shared; `Workspace` refuses the store as
  a workspace), another sandbox (separate VMs, no network between them), the Mac's keychain or login
  (read only by the host), any other vsock listener on the Mac. `make test-cli-agentsudo` checks:
  sudo apt-get install as the agent, `--no-agent-sudo`, the setting at the next boot, and as root: only
  `lo`, a denied host still denied, no vsock listener but the proxy (5800, the positive control), no
  store or host socket in the guest. Keep any new host-side vsock listener, share or credential path
  out of the guest's reach, and extend that check when one is added.
- **The `doz` host is the ONE owner of a store's VMs.** It holds `<store>/host.lock` for its
  whole life and loads nothing before it has it (a new host waits for an exiting one — otherwise it
  would read a record still saying `running` and report a live sandbox as died). The launcher is a
  detached child with ONLY stdin/stdout/stderr (`POSIX_SPAWN_CLOEXEC_DEFAULT`): a host that inherited
  a caller's pipe kept a test harness waiting on EOF. No launchd agent.
- **An update must never cost a sleeping sandbox its sessions** (an earlier incident: `make install-cli`
  overwrote the installed `doz` IN PLACE while a host ran from it; macOS invalidated the process's
  code and VZ refused every VM with "Internal Virtualization error"; quitting that host then ran the stop
  steps on two failed wakes and deleted their snapshots). The rules that came of it:
  - **Install by rename, never in place** (`install-cli`: copy + sign as `.doz.new`, `mv` over): a
    running host keeps its own file (inode). e1af862.
  - **A quit keeps a failed wake's snapshot** (`prepareForExit`, `.failed` with a restorable state) —
    only Shut Down discards one. e1af862.
  - **A host knows its own program** (`ExecutableIdentity`: path, inode, device, size, mtime, cdhash at
    start; `SecCodeCheckValidity` of itself). Overwritten (or its code invalid) → every error of a VM op
    becomes "this host's program was updated underneath it — `doz host stop`, then retry"
    (`HostCore.explain`, also on attach), `host status` carries `executableChange`/`executableNote`, and
    `doctor` FAILS. Replaced by rename → a note; and a host whose program changed exits by itself once
    nothing is live and no client is connected (`idleLoop`), so the next command runs the new build.
  - **Every snapshot records its VM** (`PersistedSandbox.vmLayout`, `VMLayout.of` in
    `PinnedIdentity.configureVZ`: platform + machine id, CPUs, memory, kernel sha256 + file, disks in
    order with read-only, NICs + MAC, balloon, vsock, serial/console, share tags, entropy, other devices;
    the command line and `recordedBy` are informational). A wake builds FROM THE RECORD where this build
    controls it (583's balloon; 591's kernel: the recorded file, or any cached `vmlinux*` with its sha256
    — `VMLayout.kernelForRestore`) and compares the VM it is about to restore into with the record
    BEFORE VZ is asked: a difference throws `snapshotNeedsOtherBuild` (keep it asleep and wake it with
    the build that slept it, or Shut Down), and the snapshot is kept. A record without a layout (pre-591)
    is best effort, as before. `VMLayoutTests`.
  - **`make test-vm-upgrade`** (a /ship gate for any release that touches the VM, the host or the
    install): the previous release's `doz` (built once from the latest tag whose tree has `Sources/DozableKit`,
    `prev-cli`; until that first tag, v0.37.0, exists, a COPY of this build — 630, like 592: the releases before the
    Dozable rename keep nothing a 0.37 build reads, by owner ruling) sleeps a lab and a pi sandbox with a running session and markers; this build wakes them — same session pid, screen,
    file — and then its own recorded layout; then the incident (the running host's file overwritten
    in place: the host says so, `host stop` keeps the snapshot, this build wakes it) and an idle host
    replaced by rename exiting by itself.
- **Settings are ONE closed schema**. A new user-facing knob is a new entry there — its type,
  default, description, env var, flag and when it applies — never a new ad-hoc env read, localStorage
  key or file. The file (`${XDG_CONFIG_HOME:-~/.config}/doz/doz.toml` — named for
  the command since 0.37) is GENERATED from the schema on every write (all settings listed, defaults commented, only set
  values uncommented; atomic, 0600 in a 0700 dir); the reader is our own strict TOML subset (strings,
  bools, ints; anything else refused with its line). An unknown key or bad value is a warning (the
  default applies); a file that does not parse is ignored whole and NEVER overwritten. Precedence
  everywhere (669): flag > env > sandbox > project > mac (the file) > default (a recipe's own, source `recipe`, or
  Dozable's), and every value carries its source (`SettingSource`; its JSON still reads `file` as `mac`). 669: a
  recipe's settings are GENERATED per recipe under `recipes.VENDOR.PRODUCT.NAME` (`DozableSettings.recipeSchema`:
  version, approvals, memory_mib, network + its `com.dozable/settings@1` options) and written only while one is set;
  their 0.37 names are aliases (read, taken by `doz config`), moved by the first write, which keeps a one-off
  `doz.toml.0.37.bak` (`writingAll`). A sandbox's own values: `SandboxConfig.settings` stays FLAT (an older doz reads
  it), `settingsFrom` says which are the project's, `recipeSettings` records the when-made ones with `from`. A
  recipe's state (in use / installed / available) is `RecipeStates`, from the store alone. The web route
  (`/api/v1/settings`) takes one `{key, value}` or `{key, reset: true}`, strictly decoded, CSRF-checked;
  the UI never sets a host path (`store.path`, `kernel.*`) nor a value the environment or a flag
  sets. NOT settable (security): the web limits and checks, tickets, paste caps, guest-binary
  overrides, credentials; `ui.terminals` can only take away. Tests use a scratch XDG_CONFIG_HOME
  (the Makefile's test targets export one; the CLI harness sets its own under its store); the web
  server's default `WebSettingsStore(environment: [:])` reads no file. 669: every control the Settings page draws
  (`settingControl`) has its specimen in the style guide's "Setting controls — every pattern" — a new setting type or a
  new control gets one there in the same commit; a preset-style setting is `settingMatrix` (`components/setting-matrix.js`,
  `defaults.permissions`'s Locked · Standard · Open matrix + its drop-down; Custom shows `permissionSwitches`).
- **A host never lives in a client's process tree** (an earlier incident, 2026-09-29: a host auto-started by
  `doz ui` was the UI's CHILD — own session, but its descendant; a tool that stopped the UI's tree
  SIGTERMed the host mid-hibernate and a sandbox lost its programs). `HostLauncher.spawn` is the ONE
  way a host is started for a client (`HostClient.connect(autostart:)`, `doz host start`): a double
  spawn — an intermediate `doz host start --launch-detached` (own session) spawns the host
  (`--foreground --launched`, own session and group, stdin /dev/null, stdout+stderr the log, no other
  descriptor), prints its pid and exits, so the host's parent is launchd (1). The client still waits
  for its socket. Only a person's `doz host start --foreground` runs in a caller's tree. `host status`
  carries `parentPid`, `sessionID`, `launchedDetached`; `doctor` warns when a launched host's parent
  isn't 1. `make test-cli` (`cliHostDetachChecks`) kills a client's group and every descendant (TERM,
  then KILL) and checks the host, a running sandbox and its session survive.
- **Names are never cut; a point is found by what a person types**: a restore point's name is
  stored as given, ≤ `RestorePoint.maximumNameLength` (64; longer is refused with the limit — names live
  only in meta.json, a point's directory is its id). `RestorePoint.resolve`: exact id, exact name
  (newest), else the ONE point whose id or name starts with it — several is an error listing them
  (`HostCore.resolvePoint`, used by the host and the CLI).
- **Check, then ask**: a confirming command resolves what it is about first — the sandbox
  (`requireSandbox`), the point (`resolvePointFirst`, then the question names name, id, when; the
  request carries the id), the image/template — so a `[y/N]` is never offered for what would fail.
- **`exec` and `run` start an off sandbox**: `HostRequest.start` (the CLI sends it unless
  `--no-start`; an older client never does) → `ensureRunning(start:)` runs `lifecycle(.start)` (boot
  view, boot log, metrics); `ExecOutput`/`SessionOpened` carry `started`/`woke`/`bootMilliseconds`.
  `doz create --start`. `make test-cli-points` covers W25–W27.
- **Looking never starts the host.** Read-only commands answer from the store in-process
  (`HostCore(readOnly: true)`) unless a host runs — or a record says a VM was live when its host went
  away, which only a host can recover. A short request does not reset the idle clock; an open
  attach or stream does.
- **The attach relay adopts the session BEFORE it answers**, and the client sends what was typed
  ahead of its first connection once it reads that answer (keys typed right after `up` were lost
  otherwise — the first `test-cli` run). After that, keys for a held (sleeping) sandbox are dropped, never queued for a frozen guest.
- **One keychain item holds at most `Keychain.maximumSecretBytes` (1800)** (599i rc.2: `security -i` cuts an input line at
  ~4096 bytes; a 4.2 KB ChatGPT sign-in was stored TRUNCATED with rc 1 on a real Mac). `SystemKeychain.write` refuses
  more before `security` runs, reads the item back and deletes it unless it is the secret whole — never a partial item; the
  in-memory test keychains (`MemoryKeychain`, the tests' `FakeKeychain`) enforce the same limit. Store less, or use
  `KeychainChunks`. `RealKeychainLimitTests` checks the real keychain (`DOZ_TEST_REAL_KEYCHAIN=1`, a throwaway
  `doz-test-limit-*` item, always deleted); the fake OpenAI issues real-sized tokens (~6 KB with a 2.1 KB refresh token).
- **Dozable never holds, uses or writes Claude Code's refresh token, and never writes a
  `Claude Code-credentials*` item**. It reads the Mac login's ACCESS token only; the Mac's
  Claude Code is the one writer of that token family (a second holder forks it — a copied
  `.credentials.json` was rejected for this in an earlier project, and for its silent fall-through to API billing).
  Renewal is the Mac's: the only thing doz may do is run the Mac's own `claude -p` (the
  keep-alive, opt-in). Every secret doz writes to the keychain goes on `security -i`'s STDIN.
- **Never inject our credential beside the guest's own** (588: the prototype added the Mac's bearer
  token next to a guest `x-api-key`). Every auth header a host's bindings use counts as "a
  credential is present"; a connection that carried the guest's own credential gets nothing
  injected afterwards. `testNeverInjectBesideTheGuestsOwnCredential` and `make test-vm-claude`.
- **A foreign credential is a fingerprint, never a value** — 12 hex of sha256, kind, a prefix of at
  most 13 characters — in the log, events, `key ls` and `ls`.
- **Placeholders persist as sha256 hashes** (`doz.json` `placeholderHashes`, D8) so a session
  survives a host restart; `shutdown`/`reset`/`rm` revoke them. A stdin key is still memory-only:
  after a host restart a sandbox holding only one has no secret, and the proxy stops decrypting.
- **No silent fallback between accounts.** A missing, expired or signed-out credential is
  answered by the proxy itself (401, an Anthropic-shaped JSON error Claude Code shows) with what
  to do — never another account's or an API key's. The account `mac` MEANS whoever is signed in on
  the Mac, so a Mac sign-in as someone else is followed, not held (owner, 2026-10-23: "this should be
  transparent to the sandboxes"): `LoginWatcher.freshen` (the vault's `onBeforeUse`, one `stat` of
  `.claude.json` at most once a second) re-reads on the next request, the new identity is pinned and
  said once. `testMacSignOutClearsAndADifferentAccountIsFollowed`.
- **What a person reads carries no internal numbers**: no feature numbers or walkthrough IDs in
  `--help`, setting descriptions, messages or the dashboard's strings — they belong in comments.
  `make docs-drift-check` runs `Scripts/user-text-check.swift` (and `Scripts/manual-check.swift` on
  `docs/manual`). Shell comments inside guest scripts are exempt: they are part of an image's recipe.
- **virtio-fs caches:** deleting a file on the HOST that the guest has cached is not visible at once
  — tests use fresh file names (this cost an afternoon of chasing a non-bug).

## Engineering docs — read the one for the area you touch

Each holds one area's rules and its full code map. The rules above apply to every change; an area's own rules
are in its doc, so read it before changing that area.

- [docs/engineering/engine.md](docs/engineering/engine.md) — the `Sandbox` actor, the lifecycle planner, VZ, disks and restore points, the kernel, deckhold, the host and its client, the CLI, settings' code, the VM suite; a host stop's progress, the guest's time zone
- [docs/engineering/network.md](docs/engineering/network.md) — subnets, `NetworkPolicy`, the egress proxy and NIOSSL, the credential vault and the CA, doznet, web ports and sign-in from Open, a model server on this Mac
- [docs/engineering/images-and-bases.md](docs/engineering/images-and-bases.md) — image specs and bakes, Claude Code's launcher, agent tools and versions, an image never rebuilt without the user, Resources, base × agent images, agent permissions
- [docs/engineering/github-and-access.md](docs/engineering/github-and-access.md) — the Mac's Claude Code login and accounts, agent credentials per agent, GitHub as the user, the Access step
- [docs/engineering/codex.md](docs/engineering/codex.md) — Codex as an agent: its launcher, accounts, Dozable's own ChatGPT sign-in, the refresh, the proxy, the guest's auth.json
- [docs/engineering/recipes.md](docs/engineering/recipes.md) — agent recipes and key providers, the recipe catalogue and community recipes, model sources, network profiles, `doz try` and Quick try
- [docs/engineering/web.md](docs/engineering/web.md) — `doz ui`: the security rules, routes, actions and operations, the page's modules and style, the installable dashboard and restarts, the sandbox pages, browser terminals
- [docs/engineering/lan.md](docs/engineering/lan.md) — `doz ui --lan`: admission, devices and invites, where it listens, sandboxes never reaching it
- [docs/engineering/terminal-tui.md](docs/engineering/terminal-tui.md) — what the CLI draws: the colour switch, `Style`, components, `Prompter`, the input seam
- [docs/engineering/onboarding.md](docs/engineering/onboarding.md) — image preparation in the host, `onboarded.json`, the setup wizard, the environment prompt, `doz_project.yaml`, `doz init`, uninstall
- [docs/engineering/sessions.md](docs/engineering/sessions.md) — saved screens and the kept layout, boot logs, the session bridges (OSC 52, the browser bridge, tmux, the Ctrl-] menu, workspace files), OSC 7501, painted thumbnails
- [docs/engineering/updates-and-release.md](docs/engineering/updates-and-release.md) — `BuildFlavor`, anonymous usage statistics and the sign-up, the signed update feed and channels, `make release`, signing, Homebrew
- [docs/engineering/workspace-rules.md](docs/engineering/workspace-rules.md) — `.dozignore` / `.dozreadonly`: `dozview`, Docker's semantics in C and Swift, modes, the wake
- [docs/engineering/tools-and-dotfiles.md](docs/engineering/tools-and-dotfiles.md) — the tools layer (gh, tmux 3.8, …) and the person's dotfiles
- [docs/engineering/files.md](docs/engineering/files.md) — the file watcher (`files-list`, `doz files`, the files routes) and the Files tab's changes, Open in an editor
- [docs/engineering/sound.md](docs/engineering/sound.md) — `sandbox.audio`, the sound kernel (GPL-2.0, ours), the microphone's permission

## Verifying changes

```bash
make build     # swift build — Xcode 27 needs the --build-system native pin the Makefile probes for
make test      # unit tests: no VM, no entitlement. Never --parallel. (web-assets-check first)
make web-assets        # 590: regenerate Sources/DozableWeb/Resources/Web after editing WebSource/ (commit it)
make css-lint          # 647: the stylesheet's rules (in make test); make css-perf: its cost in headless Chrome vs the baseline
make audit     # Scripts/audit.sh
make test-vm   # the VM integration suite — see below
make cli       # 585: build + sign .build/debug/doz
make test-cli  # 585: the signed doz from separate processes, scratch store $TMPDIR/doz-clitest-store
make test-vm-claude  # 588: Claude credentials through the proxy with a FAKE key (DOZ_TEST_CLAUDE_LOGIN=1 adds this Mac's login, read-only)
make test-vm-upgrade # 591: the previous release sleeps sandboxes, this build wakes them; the in-place overwrite incident (scratch store $TMPDIR/doz-upgrade-store)
make test-vm-templates # 593: templates and duplicates on pi — no state disk in a template; duplicate's workspace and fresh/copied state disk
make test-cli-onboarding # 594: test-cli's onboarding part alone (onboard, a joining start, detach/cancel, init/up, the agent prompt, uninstall)
make test-cli-timezone # 594 W10: the Mac's (stubbed) zone at boot and every wake, or sandbox.timezone
make test-cli-bases  # 596: base × agent — cli, Dockerfiles via a fake container, the real container build (SKIPs unless Apple's services run; BASES_START_BUILDER=1), the VM matrix (BASES_PARTS=…)
make test-cli-permissions # 597: agent permissions — net show/allow/deny/permissions, create --allow, Claude Code's hosts reached under Standard, suggestions, live changes, facts, stored by name (prepares claude-code; network)
make test-cli-points # 594 W25–W27: point names/lookup, check before asking, exec/run start an off sandbox
make test-cli-agentsudo # 594 W23: the agent's sudo in a fresh claude-code sandbox (prepares it; network), --no-agent-sudo, the setting at the next boot, root reaches no more
make test-recipe-catalogue # 652: the recipe catalogue end to end — publish (throwaway key) into a DIRECTORY_DIR (CNAME, .nojekyll, index.json; the update site refused) → a local server standing in for doz.sh → the host's refresh → the next start uses it; doz.sh/… names resolve with no request; tampered refused
make test-community-recipes # 653: your own recipes and community catalogues end to end (throwaway keys, a local server): check fails then passes, labels, Dozable's id refused, confirm before fetch, a clash refused whole, tampered refused, removal keeps a sandbox
make recipe-check RECIPES=all # 617: every recipe for real — build, verify, a fresh try, its check turn against a stand-in provider, keys, leak guard, OSC 7501 states (report: $RECIPE_STORE/report.json)
make test-cli-codex # 599i: Codex through seams (a fake OpenAI over TLS, the browser seam): Dozable's own ChatGPT sign-in, the swap, the Mac's renewal, no token in the guest, an API key, Alpine (prepares codex + alpine-codex)
make test-cli-github # 599d: GitHub as the user through seams (a fake GitHub, a fake gh, a throwaway ssh-agent): swap, read-only, push, no leak, identity, key source, off, SSH
make test-cli-openfiles # 599b: workspace files opened on the Mac through the opener seam — every refusal, isolated, off, --app, URLs as before
make test-cli-dotfiles # 657: your dotfiles in real VMs — local scratch repositories, the install script and the link pass, Dozable's own untouched, trust refused off a terminal, --update, never applied twice (prepares claude-code)
make test-cli-files  # 643: doz files — listed/watched on the Mac (no host, rules, a link out refused, nothing woken); isolated listed inside while running
make test-vm-cwd     # BUG cwd-after-wake: a program's cwd in /workspace across sleep, hibernate and a new-process restore (the raw share as the control); the passthrough view's cost
make test-vm-ignore  # 599g: workspace rules (.dozignore lock/hide, .dozreadonly) across boot/pause/sleep/hibernate/new-process restore, reload, folding, kills (scratch store); then test-vm-agentwrite
make test-vm-agentwrite # the agent (a non-root image user) writes shared workspaces through the view: Dozable-made, 755/644, 700/600, rules; git; rules still refused; sleep/hibernate (also run by test-vm-cwd)
make dozview / dozview-verify # 599g: rebuild the guest view daemon (pinned Zig) / check the committed bytes
make tmux / tmux-verify # 658: rebuild the guest tmux 3.8 (pinned Zig, sha256-pinned tmux/libevent/ncurses) / check the committed bytes
make sound-kernel    # 667: build the sound kernel from source (twice, a throwaway ubuntu VM, network, ~7.5 min) and check it is SoundKernel.sha256 (SOUND_KERNEL_OUT)
make test-cli-tmux38 # 658: Dozable's tmux 3.8 on Debian + Alpine (prepares both): the bridges through it, the theme reported, OSC 7501 measured, an older distro tmux session kept and ended
make deckhold / deckhold-verify / deckhold-snapshot-check # the guest PTY holder: rebuild (pinned Zig + ghostty) / check the committed bytes / 610: its snapshot equals its screen, cell by cell
make deckhold-status-check # 612: deckhold's OSC 7501 consumer — the query answered, the records' rules and limits, invalid input, every cut offset + a fuzz
make deckhold-grid-check # 648: deckhold's GRID — every row's text is the holder's screen, colours/flags/cursor, the gen, the limits, the announcement (+ a fuzz)
make test-cli-grids  # 648: session-grids through a real host — a coloured session's grid, unchanged/moved gens, asleep stays asleep with a saved grid, no host starts nothing
make test FILTER=Suite # the matching unit tests only (swift test --filter)
make test-vm-status  # 612: a FAKE agent's status through deckhold, the host and the CLI — no viewer and a viewer, sleep/hibernate + wake, the exit, shutdown (scratch store)
make test-cli-hoststop # 594 W22: test-cli's host-stop part alone (per-sandbox progress plain/animated, --json, nothing running, a host killed mid-stop)
make pullbench       # 594 D12: the node base pulled with 3 vs 6 concurrent layer downloads, fresh stores (network)
```

### Test safety is the default

Every `make test*` target (and the probes' `guard-doz.sh`) runs with `DOZ_TEST_GUARD=1`,
`DOZ_TEST_NO_MAC_LOGIN=1`, `DOZ_TEST_CREDENTIALS=memory`, a scratch `DOZ_TEST_CODEX_HOME` and a scratch
`XDG_CONFIG_HOME` whose `doz.toml` sets `store.path` and `defaults.projects_dir` to scratch folders — forced,
whatever the environment says. `TestSafety` (DozableHost) STOPS a guarded process (and any XCTest run) that
would use the default store, read the Mac's real `~/.codex`, or touch the login keychain's `Claude Code-credentials*`
items. The only way out is explicit: `DOZ_TEST_REAL_MAC=1`. A new code path that reads something of the
Mac's own must go through a seam the Makefile sets (`CredentialServices.forHost`, `macLoginKeychain`) —
`TestSafetyTests` pins the decisions.

**Paths are SHOWN with `~`** (617): `DisplayPath` (DozableHost: `tilde`, `tildeIn`, `homes`) and its twin `core/paths.js`
(`tildePath`, `tildeIn`, fed the session info's `homes`) are the ONE way a Mac path is shown — the sidebar's store, the
try banner, the Guide's facts, the details' workspace, a Dockerfile, the plan's lines, Doctor, and the CLI's human lines
that name a folder. Display only: stored values, requests and every JSON field stay absolute. Home is the REAL one
(`TestSafety.realHome`); the seam `DOZ_TEST_HOME=/tmp/…` stands in for it on screen only, and only in a guarded run (the
release post's screenshots: `probes/617-*/stageE/release-shots.mjs`). Nothing else reads it.

### The VM integration tests need an ENTITLED host — how

`swift test` runs an XCTest bundle inside `xctest`, which does not (and cannot be made to) carry
`com.apple.security.virtualization`, so no VM can start there. The integration suite is therefore
an executable target, `doz-vmtest`, that `make test-vm`:

1. builds (`swift build --product doz-vmtest`),
2. ad-hoc signs with `Scripts/vmtest.entitlements` (`codesign --force --sign - --entitlements …`),
3. runs under a watchdog (`perl -e 'alarm 420; exec @ARGV' …`) so a VM op that never completes
   fails the run instead of wedging it; stdout is line-buffered so a hang shows where it stopped.

It prints one `PASS`/`FAIL` line per check and `vmtest: ALL PASS` last. Modes: `all` (default),
`network` (`make test-vm-network`: the claude-code image proxied; live-prompt check SKIPs
without `ANTHROPIC_API_KEY`), `lineage [part]` (`make test-vm-lineage`: bake, discard, sync,
journal, nojournal, accounting, reclaim, rederive, children; 587's v0.4.0 compatibility item was
retired by 592), `netdebug --script '…'`, `lifecycle`, `crash` (spawns itself as `crash-save` — start, session, sleep to disk, exit without
stopping — then restores in the parent), `crash-restore`.

- **Store:** `VMTEST_STORE` (default `$TMPDIR/doz-vmtest-store`) — a SCRATCH store, never an app's
  storage root. The first run in a new store pulls images and bakes `bash ncurses` (~40 s, network).
- **Coexistence:** sandboxes are named `vmtest` / `vmtest-crash`; the suite touches nothing outside
  its store and never kills a process it did not start, so SandboxLab or a probe can run beside it.
- **Kernel:** the library's pinned kernel via `KernelProvider`, cached in `KERNEL_CACHE` (exported
  as `$DOZ_KERNEL_CACHE`; default: under the store). `make kernel` fetches it alone.
  `DOZ_KERNEL=<path>` boots an explicit kernel instead.
- A VM test is green when it is green **twice in a row**.

## Contributing

Issues and fixes are welcome directly; see `CONTRIBUTING.md`.
