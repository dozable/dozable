# CLAUDE.md

The engineering guide to Dozable — for contributors and for coding agents alike: what each part is, where
the code lives, the rules that each cost a bug to learn (keep them, and their tests), and how a change is verified.
The user manual is `docs/manual/`; the developer view of the engine is `docs/DOZABLEKIT.md`.

**Reading the history in this repository.** Dozable is developed in a private workspace and released from here. Code
comments and a few notes below cite the feature that introduced something by its number (`591`, `599i`) and the
design notes or probes it came from (`changes/591-*/…`, `probes/…`) — those live in that workspace, not here; the rule they explain is always stated where it is cited. "SandboxLab" is the earlier prototype app the engine grew out of; "DeckStack" and "Deckosaurus" are sibling projects some techniques were taken from (never a dependency).

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
| `DozableKit` | `DozableKit` (+ resources `deckhold`, `doznet`, `dozview`, `tmux`, `dozchat`); test-only C target `DozMatch` (`Guest/dozview/match`) | `apple/containerization` **exact** `0.47.0`: `Containerization`, `ContainerizationArchive` (the kernel tarball), `ContainerizationExtras`, `ContainerizationOCI`, `ContainerizationOS`; since 580 `swift-nio` (`NIOCore`, `NIOEmbedded`; 583 `NIOPosix`), `swift-nio-ssl` (`NIOSSL`), `swift-certificates` (`X509`), `swift-asn1` — apple/* packages containerization already resolves (README "Dependencies") |
| `doz` (executable, 585) | `doz` → `DozableCLI` (commands) → `DozableHost` (the daemon + its client); 637: `DozableCLI` → `DozableTUI` (terminal components, the colour switch — Foundation + Darwin only, audit) | `DozableKit`; `swift-argument-parser` (`ArgumentParser`) in `DozableCLI`/`doz` ONLY; the system `SQLite3` in `DozableHost` (metrics); `jpsim/Yams` **exact** `6.2.2` in `DozableCLI` ONLY (`doz_project.yaml`, and space files — `SpaceResolver`: the daemon receives one merged JSON document and never parses YAML or opens a space file; the audit enforces the pin and the confinement); 667: the system's `AVFoundation` in `DozableHost/Microphone.swift` ONLY (the microphone's permission — never a capture; audit) |
| — (not a product) | `DozableWeb` — `doz ui`'s server and page (645: one server — this Mac's browser and, with the LAN option, the network's) | `DozableHost`; `swift-nio` `NIOCore`/`NIOPosix`/**`NIOHTTP1`**/**`NIOWebSocket`** (both ONLY here — the audit enforces it); the system's **`dnssd`** (Bonjour) in `WebBonjour.swift` ONLY (audit); resource `Resources/Web` (generated, committed). `DozableCLI`'s `UICommand.swift` alone imports `CoreServices` (LaunchServices opens the browser) |
| — (not a product) | `doz-vmtest` — the entitled VM test host | `DozableKit`, `DozableHost` (the `cli` mode decodes `--json` with its types) |
| `Dozable` (executable: the menu bar app, `Dozable.app`) | `DozableMenuBar` (AppKit and ServiceManagement, there ONLY — ServiceManagement in `LoginService.swift` alone) → `DozableMenuBarCore` (Foundation, Security, os) | nothing of this package and no package — it runs the `doz` command (the audit holds it) |

The Containerization pin is EXACT on purpose: the sleep design leans on its internals' shape — `LinuxContainer.withVirtualMachineInstance` handing out a `VZVirtualMachineInstance`, the `VZInstanceExtension` hook, the public `VirtualMachineManager` / `VirtualMachineAgent` protocols,
and how `LinuxContainer.create()/start()/stop()` call them. A bump is a deliberate re-verification: `make test-vm` green twice.

## Where the code lives

One row per area; each area's doc starts with the full table of its files.

| Area | Where | Detail |
|---|---|---|
| The engine and the daemon | `Sources/DozableKit/` (Sandbox, Phase, VirtualMachine, disks, restore points, kernel), `Guest/deckhold/`, `Sources/DozableHost/` (HostCore, HostServer, HostClient, Settings), `Sources/DozableCLI/`, `Sources/doz-vmtest/` | [engine.md](docs/engineering/engine.md) |
| The network | `SubnetPool`, `NetworkPolicy`, `EgressProxy`, `Credentials`, `SandboxCA`, `Guest/doznet/`, `PortForwarding`, `MacModelServer` | [network.md](docs/engineering/network.md) |
| Images, bases, agents, resources | `ImageSpec`, `ImageBaker`, `BaseCatalogue`, `AgentPermissions`, `Resources.swift`, `ImageTree` | [images-and-bases.md](docs/engineering/images-and-bases.md) |
| Accounts, GitHub, Access | `ClaudeLogin`, `Accounts`, `LoginWatcher`, `HostCore+Accounts` | [github-and-access.md](docs/engineering/github-and-access.md) |
| Codex | `OpenAIAccess`, `ChatGPTAccounts`, `ChatGPTSignIn` | [codex.md](docs/engineering/codex.md) |
| Agent recipes, key providers, the catalogue | `RecipeCatalogue`, `RecipeOrigin`, `RecipeCommands`, `Scripts/publish-recipes.sh` | [recipes.md](docs/engineering/recipes.md) |
| `doz ui` — the web layer (Home, the sidebar, This Mac, a workspace's page — its Home tab `views/ws-home.js` and its cards `components/ws-card.js` —, the Workspaces page `views/workspaces.js` with a row's next action `components/ws-next.js`; the addresses in `core/routes.js`; the workspace reads in `WebWorkspaces`; the workspace drawn: `core/space-pictures.js`, `components/space-picture.js`; the space editor's page `views/space-page.js` with its data `core/space-editor.js`; the editor's build in `vendor/space-editor/`) | `Sources/DozableWeb/`, `WebSource/` → `Resources/Web/`, `Tests/DozableWebTests/` | [web.md](docs/engineering/web.md) |
| The LAN option | `Sources/DozableWeb/WebServe*.swift`, `WebExposure`, `WebBonjour` | [lan.md](docs/engineering/lan.md) |
| The terminal | `Sources/DozableTUI/` | [terminal-tui.md](docs/engineering/terminal-tui.md) |
| Onboarding, projects | `Preparations`, `Onboarding`, `AgentPrompt`, `OnboardCommands`, `ProjectFile` | [onboarding.md](docs/engineering/onboarding.md) |
| Sessions | `SavedScreens`, `BootLogs`, `SessionStatus`, `ScreenGrid`, the attach relay's bridges; sessions on this Mac (`MacSessions`, `MacPlace`, `DeckholdSocket`) | [sessions.md](docs/engineering/sessions.md) |
| Builds, statistics, updates, release | `Usage.swift`, `Updates.swift`, `Scripts/release.sh` | [updates-and-release.md](docs/engineering/updates-and-release.md) |
| Folder rules (`.dozignore`, `.dozreadonly`) | `Guest/dozview/`, `DockerIgnore`, `WorkspaceRules`, `WorkspaceView` | [workspace-rules.md](docs/engineering/workspace-rules.md) |
| Tools layer, tmux, dotfiles | `Guest/tmux/`, `Dotfiles.swift` | [tools-and-dotfiles.md](docs/engineering/tools-and-dotfiles.md) |
| Files | `WorkspaceFileList`, `WorkspaceFileChange`, `FileWatch`, `EditorApps`, `WebFiles` | [files.md](docs/engineering/files.md) |
| Sound | `Audio.swift`, `DozSound.swift`, `MacAudio`, `Microphone`, `Guest/sound-kernel/` | [sound.md](docs/engineering/sound.md) |
| The chat server (the `doz chat` group) | `Sources/DozableChat/`, `Sources/DozableHost/Chat*.swift` (under the daemon), `Sources/DozableCLI/Chat*.swift`, `Tests/Conformance/`; in the dashboard `Sources/DozableWeb/WebChat.swift`, `WebSource/app/*/chat*.js` | [chat.md](docs/engineering/chat.md), [web.md](docs/engineering/web.md) ("Chat") |
| The menu bar app | `Sources/DozableMenuBarCore/`, `Sources/DozableMenuBar/`, `Resources/MenuBar/` (+ the login agent's plist), `Scripts/assemble-app.sh`, `Scripts/check-agent-plist.py`, `AppCommands.swift` (`doz app`) | [menu-bar-app.md](docs/engineering/menu-bar-app.md) |
| Workspaces, their workers and Agents / Bots (`doz workspace`, `doz worker`, `doz bot`); space files (`doz space`) | `WorkspaceRecord`, `WorkspaceStore`, `WorkspaceState`, `HostCore+Workspaces`, `ChatOwnerRooms`, `WorkspaceCommands`; the wide views `WorkspaceReach`, `WorkspaceChangedFiles`, `HostCore+WorkspaceViews`; `WorkerLaunch`, `HostCore+Workers`, `WorkerCommands`; `BotRecord`, `BotStore`, `BotTokens`, `HostCore+Bots`, `BotCommands`; `SpaceResolver`, `SpaceValidator`, `SpaceIntent`, `SpaceUp`, `SpaceCommands`; a space's file, state and frames `SpaceRecordFile`, `SpaceState`, `SpaceStateRecorder`, `HostCore+SpaceState`, `WebSpace` | [workspaces.md](docs/engineering/workspaces.md) |

## Rules that each cost a bug to learn (keep them, and keep their tests)

- **Sessions start WITHOUT `sh -c`.** BusyBox ash leaks an ignored SIGQUIT into what it execs, and a
  program cannot trap a signal ignored on entry (576: the screensaver's `m` menu). `GuestCommand.serve`
  builds argv; deckhold additionally resets every signal to default before exec. Utility execs
  (`exec(["sh","-c",…])`) may use a shell — never a session.
- **A session on this Mac (`@mac`) is never a sandbox and never bypasses permissions by default.** No code path
  treats `@mac` as a sandbox (no `Managed`, no `Sandbox` — `HostCore.perform` routes it first); a proxy and placeholders
  exist ONLY inside the fence (`MacFence`), per session, served by the daemon on a socket its holder owns; nothing a
  fenced program can write is later executed or loaded by anything unfenced except the project's own files (per-session
  temp, caches and agent config; git hooks and config guarded); the environment is an allowlist the fence adds to
  (`MacSessionsEnvironment`, then `MacFenceEnvironment`: never `CLAUDECODE`/`CLAUDE_CODE_*` of the daemon's); the holder
  starts by `posix_spawn` (never `sh -c`) outside the fence; a bypass flag is only ever the session's own argv, marked
  wherever it shows. Fenced is the default for a NEW session (`mac.fence`, `--unfenced` opts out); a record keeps its
  mode across restart, resume and adoption (nil `fence` = unfenced — every record written before the fence). An
  unfenced session has no proxy and no placeholder, ever. `MacPlaceTests`, `MacSessionsEnvironmentTests`,
  `MacFenceProfileTests`, `MacFencePathsTests`, `MacFenceEnvironmentTests`, `MacFenceHostFSTests`, `MacFenceGitTests`,
  `MacAgentConfigTests`, `MacFenceCapabilitiesTests`, `make test-cli-fence` (the fence end to end, the default and
  the mode kept on restart) and `make test-cli-host` (the unfenced session, unchanged, with `--unfenced`).
- **Every `doz exec` deadline is counted from process start and enforced by the daemon** (`ExecDeadline`; engine.md).
- **Stop keeps the root disk**: Stop shuts the VM down and persists the phase as `off`; the next Start cold-boots
  the SAME disk and clones the prepared disk only when none exists. `resetToImage()` discards the root disk; `delete()`
  removes the sandbox's whole directory. No Stop leaves a snapshot, and a snapshot found beside a kept disk on a cold
  Start is deleted — never restored onto a disk that has moved on.
- **One vmnet network per `Sandbox`, and never vmnet's default subnet beside another process.** Each
  Start used to create a new vmnet network (after a handful the guest had no route out); it is now
  created once and reused. Two processes that both take the default can get the same subnet and the
  same guest addresses — the NAT then silently drops one (the gateway still answers ping). Since 583
  the library never takes the default: with no `SandboxSpec.subnet` a NAT sandbox (and a NAT bake)
  gets a free /24 from 192.168.100–199 (`SubnetPool`: none a daemon interface is on, none this process
  holds, tried from a random start); an explicit subnet stays an override. The test hosts still pin
  192.168.201/202.0/24. `hardening subnets` is the test.
- **Every sandbox VM uses the ONE shared event-loop group** (`SharedEventLoop.group`, 583). Left to
  itself `VZVirtualMachineInstance` makes an 8-thread group and shuts it down only in its own `stop()`,
  which Hibernate never calls — each VM instance a daemon made kept 8 threads + 8 kqueues forever (582;
  thread cap 6,144). `hardening leak` is the regression test (threads, fds, footprint flat).
- **Quit lets a just-started program settle**. `prepareForExit(settle:)` waits out the rest of 3 s since the last `openSession` before it hibernates (580: Claude Code hibernated within ~1 s of its launch exited after the wake in 2 of ~7 runs). `hardening settle` is the test.
- **Stop decides from the phase it was CALLED in** (`perform()` reads `phase` before going busy).
- **Every VM has a memory balloon; a snapshot is never taken with it inflated**. A device is a
  VM input: `PinnedIdentity.memoryBalloon` comes from `PersistedSandbox.memoryBalloon` on a restore
  (nil = an older build's VM — restore it WITHOUT one) and is true on every cold boot. `wake()`
  inflates it over free guest pages — 651: AFTER the wake is reported done, the last of its background
  steps (see "A wake is done when the guest runs") — and it STAYS inflated (VZ charges the pages again on deflate —
  measured) UNLESS the guest needs it (678 B7: an 8 GiB guest ballooned to a quarter wedged under npm installs —
  atomic allocations failed, its OOM killer never ran, so deflate-on-OOM never fired): the reserve is at least half
  plus what runs (`BalloonPressure.reserveMiB`); no inflate while a session reports `working` (it waits for idle);
  while the balloon holds anything the DAEMON reads the guest's `/proc/meminfo` every 2 s and deflates at once, from its
  side (VZ's target needs no guest answer), when `MemAvailable` falls under the reserve, a read takes over 3 s, a
  session turns `working` or a session opens. An early deflate leaves the balloon UNCONFIRMED (`balloonDirty`) until
  a deflate sees the guest's `Balloon:` at 0 — a snapshot path throws rather than snapshot it. `hardening balloon-pressure`. `.restoreGuestMemory` runs before every pause-for-snapshot, and `saveSnapshot` deflates
  a paused one (resume → deflate → pause): a snapshot of an inflated balloon fails to restore
  (`VZErrorDomain 12 invalid argument`). Progress is read from the guest's `/proc/meminfo`
  `Balloon:` line — VZ offers DEFLATE_ON_OOM, so MemTotal never moves.
- **Stop is always graceful.** A paused VM is resumed and a VM on disk restored (silently — no phase event) and then `LinuxContainer.stop()` runs. Stopping at the VZ level instead leaves the package's
  vminitd gRPC clients unclosed, and deallocating one is a FATAL error (`Deinited NIOAsyncWriter without calling finish()`, seen in the 578 suite). Anything that could
  not be stopped through the package goes to `Graveyard` rather than being deallocated. Every exec is `delete()`d, including on error paths — deletion is what closes its client.
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
  `restoreAfterCrash()` return — the phase running, the daemon's answer sent — once the guest runs with its
  clock re-synced, its shares re-mounted (programs need them) and the snapshot deleted. The rest
  (`LifecyclePlanner.afterWake` / `afterAdoption`: `.applyGuestFixes` — the guest fixes, `refreshDeckhold`, the
  tools layer — then `.returnFreeMemory`) runs in `Sandbox.runAfterWake`, a task of the actor that OWNS the
  lifecycle gate the wake took (`perform` hands it over instead of releasing it), so every later lifecycle call,
  restore point, capture, rename and `prepareForExit` waits for it — never a snapshot mid-balloon or inflated. A
  waiting sleep/hibernate/stop/reset/delete/quit skips what is left at a step boundary (the next wake applies it
  again), a waiting pause only the balloon (`skippedWhenWaiting`). Best effort: a failure is a note, never a failed
  wake. `openSession` and the public `exec` wait for it (`afterWakeSettled()`) — open-session re-applies only the
  open-URL shim and (agent images) the sudo rule, not /etc/hosts, debconf, git, the SSH agent or this build's
  deckhold — and the daemon's open-session waits anyway (`refreshWorkspaceViews` takes the gate); an attach does
  not wait. The event stream ends it with `SandboxEvent.afterWakeDone` (never a client's event): the daemon's boot
  log keeps recording until then (`Managed.bootTail`, `BootRecorder.seal`) and is written after it — its time is
  the wake's to its end, the background steps one "after the wake, in the background" step. `LifecycleTests`.
- **Connections are identified by object, never by a file descriptor number,** and a closed
  connection never delivers or sends a byte (the 576 recycled-fd Stop bug).
- **Crash restore = identical VM + adoption.** The machine identifier and the NIC's MAC are pinned
  (`PinnedIdentity`), the vmnet subnet reused, and `AdoptingAgent` answers `LinuxContainer`'s
  guest SET-UP calls as already done while the restored guest is adopted.
- **The library owns its kernel.** Never read `~/Library/Application Support/com.apple.container`
  as a source of truth (the runners have no `container` CLI; that file is another tool's to change).
  A file there is used only as a SEED, and only when its sha256 equals the pin. 675: every release carries the pin at
  `libexec/doz/kernels/` (+ its GPL source offer, `Guest/kernel/`) — the FIRST seed, copied into the store's cache,
  never booted in place (a snapshot records the cache's file; an upgrade removes the program's folder). A kernel change is a
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
  hibernation lost the last ~5 s of writes in every journal mode. It also records `df` usage for `DiskAccounting`'s fallback garbage.
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
- **A proxied VM has NO NIC; the daemon proxy is the only way out**. The guest shim decides
  nothing. Every boot, crash restore and wake re-registers the proxy's vsock listener
  (`listenForEgress`) — the listener happened to survive a same-process wake in the probe, but a
  crash restore is a new VM.
- **A real key given to `openSession`/`exec` is moved into the vault** and replaced by a
  placeholder; keep it that way — "keys never enter the sandbox" rests on it.
- **This Mac's loopback is never a sandbox's** (660): a proxied sandbox's traffic leaves from the daemon process, so a
  connection the proxy makes to `127.0.0.1`/`localhost`/`::1` IS the Mac's — another sandbox's forwarded web port, a
  database, a local model server. `Wire.connectTCP` refuses a loopback or unspecified address whatever the policy (Open
  included; the tunnel and plain-HTTP paths answer 403 `loopbackRefusal` first), like 606's dashboard ports. The ONLY
  ways through: the proxy's guarded test seams (a fake upstream on 127.0.0.1) and the host-port list
  (`EgressProxy.hostPorts`, 691) — the ports of this Mac a sandbox or fenced session was given (`--host-port PORT[:tag]`,
  `doz net allow NAME host:PORT` while `network.host_ports_live` is on), of which the model server's port
  (`EgressProxy.macModelPort`, `SandboxConfig.localModelPort`, `--provider local --local-port N`) is one entry — reached
  ONLY by name, `host.dozable.internal:N` or its alias `mac.dozable.internal:N` (the proxy's DNS answers a synthetic
  198.18.255.254 and routes it to 127.0.0.1:N; any other port of the name is refused naming the open ones; no port:
  NXDOMAIN); the same port by an address of this Mac stays refused. Never Dozable's own ports (`HostRoute.refusal`, at
  grant and at each connection), never a policy rule (no preset or edit widens it; Open does not include it).
  `MacModelServerTests`, `HostRouteTests`, `HostPortsTests`, the fence rows `691`, the workspace's
  `probes/660-*/vm-proof.py`. Keep any new route to the Mac's own addresses behind the same refusal.
  **The same holds for every other address of this Mac, link-local and metadata** (683): every proxy's
  `addressGuard` is `.strict` (`AddressGuard`, the default of `EgressProxy` — a sandbox's, a bake's, a fenced `@mac`
  session's), checked in `Wire.connectTCPGuarded` on each RESOLVED address it would dial: also every address of this
  Mac's interfaces (its LAN, Tailscale and vmnet bridge addresses — a server on `0.0.0.0` answers on them), link-local
  `169.254/16` (cloud metadata `169.254.169.254`) and `fe80::/10`, multicast/broadcast, `0/8`, site-local, and the IPv6
  forms that carry an IPv4 address (mapped, compatible, NAT64) judged by the address inside — whatever the policy, Open
  included; the answer is 403 naming why (a sandbox's also names `host.dozable.internal`). The deliberate ways through
  are the two above and nothing else: `macRoute` dials 127.0.0.1 with `allowLoopback`, and the seams. Never set
  `addressGuard` to nil or `.loopback` in the product. `SandboxAddressGuardTests`, `AddressGuardTests`,
  `MacModelServerTests` (`testTheNamedPortStillAnswersUnderTheStrictGuard`), `make test-vm-network` ("the address
  guard under Open").
- **The agent has passwordless sudo by default**. The dev baseline
  installs `sudo` and KEEPS apt's package lists (~18 MiB, shared by APFS clones; `apt-get clean` only),
  and `apt-utils` FIRST (W24: otherwise every install says "debconf: delaying package configuration");
  the rule itself is never baked: `GuestCommand.agentSudoScript` writes `/etc/sudoers.d/doz-agent`
  (0440, root, `user ALL=(ALL) NOPASSWD:ALL`, put in place only after `/usr/sbin/visudo -cf` accepts it;
  absolute paths — a utility exec's PATH may lack sbin) or removes it — at every fresh boot
  (`prepareGuest`, from `Sandbox.agentSudo`), every wake (W34: `GuestCommand.guestFixes` — the live-safe
  part of `prepareGuest`: /etc/hosts, debconf Noninteractive, the open-URL shim, the time zone, the sudo
  rule — run as ONE root exec by `LifecycleStep.applyGuestFixes` after a wake from sleep, from
  hibernation and a restore after a daemon restart — 651: after the wake is reported done, in its background
  steps, which a session open waits for; never on a resume from Pause; best effort, a failure
  is noted; NOT the deckhold socket reset or the bind mounts) and every agent session start (`deliverAgentPrompt`), so a
  toggle needs no rebake. The value: `SandboxConfig.agentSudo` (`--[no-]agent-sudo`, `agent_sudo` in
  doz_project.yaml, synced by `doz up` through `agent-prompt`'s `agentSudo`/`clearAgentSudo`) else the
  setting `sandbox.agent_sudo` (read per request — `HostCore.agentSudo`). The facts block and skill say
  it (`sandbox.sudo`, `sudo.description`). **Security: root inside the VM must reach nothing the agent
  cannot** — the boundary is the VM (no NIC; the only way out is the proxy's vsock listener, where the
  policy is judged), the proxy/allow list and the absent credentials (the vault stays on the Mac).
  Root must never reach: the daemon's socket or the store (never shared; `Workspace` refuses the store as
  a sandbox's folder), another sandbox (separate VMs, no network between them), the Mac's keychain or login
  (read only by the daemon), any other vsock listener on the Mac. `make test-cli-agentsudo` checks:
  sudo apt-get install as the agent, `--no-agent-sudo`, the setting at the next boot, and as root: only
  `lo`, a denied host still denied, no vsock listener but the proxy (5800, the positive control), no
  store or daemon socket in the guest. Keep any new daemon-side vsock listener, share or credential path
  out of the guest's reach, and extend that check when one is added.
- **The `doz` daemon is the ONE owner of a store's VMs.** It holds `<store>/daemon.lock` for its
  whole life and loads nothing before it has it (a new daemon waits for an exiting one — otherwise it
  would read a record still saying `running` and report a live sandbox as died). The launcher is a
  detached child with ONLY stdin/stdout/stderr (`POSIX_SPAWN_CLOEXEC_DEFAULT`): a daemon that inherited
  a caller's pipe kept a test harness waiting on EOF. **launchd never runs the daemon** (694): only with consent
  (`daemon.login_item on`) ONE login item per store runs `doz daemon start --login-item`, which spawns it and exits
  (engine.md, "The login item"); the menu bar app's Start at Login is the other holder (its SMAppService agent execs the same
  command; while its job is loaded and the app installed, doz removes its own — never two: `DaemonLoginItem.appJob`). The
  daemon is the code's "host" (`HostServer`, `HostCore`, `HostClient`, `HostLauncher`, `DozableHost`, the wire protocol's names keep it). TEMPORARY (0.50, until the dated backlog item removes it):
  `Sources/DozableHost/Migration/HostToDaemon.swift` carries a 0.40 store across — a daemon also takes the older build's
  `host.lock` (after `daemon.lock`, waiting the same way) and holds both, a client reaches an older daemon on `host.sock`,
  `host.log` is adopted once, doz.toml's `host.*` are read and moved like a 0.37 name, and a 0.40 host's hand-over argv
  (`host start --launch-detached` / `--foreground --launched`) is taken as `daemon start`; nothing else may name it
  (`HostToDaemonMigrationTests`), and `make test-vm-upgrade` D/E prove it.
- **An update must never cost a sleeping sandbox its sessions** (an earlier incident: `make install-cli`
  overwrote the installed `doz` IN PLACE while a daemon ran from it; macOS invalidated the process's
  code and VZ refused every VM with "Internal Virtualization error"; quitting that daemon then ran the stop
  steps on two failed wakes and deleted their snapshots). The rules that came of it:
  - **Install by rename, never in place** (`install-cli`: copy + sign as `.doz.new`, `mv` over): a
    running daemon keeps its own file (inode). e1af862.
  - **A quit keeps a failed wake's snapshot** (`prepareForExit`, `.failed` with a restorable state) —
    only Shut Down discards one. e1af862.
  - **A daemon knows its own program** (`ExecutableIdentity`: path, inode, device, size, mtime, cdhash at
    start; `SecCodeCheckValidity` of itself). Overwritten (or its code invalid) → every error of a VM op
    becomes "this daemon's program was updated underneath it — `doz daemon stop`, then retry"
    (`HostCore.explain`, also on attach), `daemon status` carries `executableChange`/`executableNote`, and
    `doctor` FAILS. Replaced by rename → a note; and with nothing live and no client, a daemon whose program changed RESTARTS
    IN PLACE when always on (693: from `StableExecutable`'s path; engine.md) and exits otherwise. `IdleDecisionTests`.
  - **Every snapshot records its VM** (`PersistedSandbox.vmLayout`, `VMLayout.of` in
    `PinnedIdentity.configureVZ`: platform + machine id, CPUs, memory, kernel sha256 + file, disks in
    order with read-only, NICs + MAC, balloon, vsock, serial/console, share tags, entropy, other devices;
    the command line and `recordedBy` are informational). A wake builds FROM THE RECORD where this build
    controls it (583's balloon; 591's kernel: the recorded file, or any cached `vmlinux*` with its sha256
    — `VMLayout.kernelForRestore`) and compares the VM it is about to restore into with the record
    BEFORE VZ is asked: a difference throws `snapshotNeedsOtherBuild` (keep it asleep and wake it with
    the build that slept it, or Shut Down), and the snapshot is kept. A record without a layout (pre-591)
    is best effort, as before. `VMLayoutTests`.
  - **`make test-vm-upgrade`** (a /ship gate for any release that touches the VM, the daemon or the
    install): the previous release's `doz` (built once from the latest tag whose tree has `Sources/DozableKit`,
    `prev-cli`; until that first tag, v0.37.0, exists, a COPY of this build — 630, like 592: the releases before the
    Dozable rename keep nothing a 0.37 build reads, by owner ruling) sleeps a lab and a pi sandbox with a running session and markers; this build wakes them — same session pid, screen,
    file — and then its own recorded layout; then the incident (the running daemon's file overwritten
    in place: the daemon says so, `daemon stop` keeps the snapshot, this build wakes it), an idle daemon
    replaced by rename exiting by itself, and (F) an always-on one restarting in place, no command typed.
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
- **A daemon never lives in a client's process tree** (an earlier incident, 2026-09-29: a daemon auto-started by
  `doz ui` was the UI's CHILD — own session, but its descendant; a tool that stopped the UI's tree
  SIGTERMed the daemon mid-hibernate and a sandbox lost its programs). `HostLauncher.spawn` is the ONE
  way a daemon is started for a client (`HostClient.connect(autostart:)`, `doz daemon start`): a double
  spawn — an intermediate `doz daemon start --launch-detached` (own session) spawns the daemon
  (`--foreground --launched`, own session and group, stdin /dev/null, stdout+stderr the log, no other
  descriptor), prints its pid and exits, so the daemon's parent is launchd (1). The client still waits
  for its socket. Only a person's `doz daemon start --foreground` runs in a caller's tree. `daemon status`
  carries `parentPid`, `sessionID`, `launchedDetached`; `doctor` warns when a launched daemon's parent
  isn't 1. `make test-cli` (`cliHostDetachChecks`) kills a client's group and every descendant (TERM,
  then KILL) and checks the daemon, a running sandbox and its session survive.
- **The menu bar app is a client of the doz COMMAND** (`--json`, an absolute path, an argv — never a shell —, a cap and a timeout), never of the socket or the engine; it never sees a dashboard link (`doz ui`'s output goes to /dev/null, never `--print-url`); it registers nothing without a click (Start at Login: the agent + the app through SMAppService, and only once launchd has the job loaded is doz told `daemon.login_item on`); its login agent runs only a doz signed by Dozable's team in a release build; it installs by rename, verified first (`doz app install`); the DEV flavour (`make app-dev`: "Dozable Dev.app", `com.dozable.app.dev`, chosen at assembly) runs only its Info.plist's `DozableDevDoz` with `XDG_CONFIG_HOME`/`DOZ_STORE` from `DozableDevConfigHome`/`DozableDevStore` (both, or no doz) and registers nothing — no Start at Login, agent or app install, refused even if reached (`MenuBarFlavour`; menu-bar-app.md, "The dev flavour"); a test never shows its menu, touches /Applications (`TestSafety.applicationsViolation`) or reaches SMAppService or /bin/launchctl (ANY test run — `MenuBarSeams.testRun` — gets the recording `LoginItemService`). `MenuModelTests`, `LoginItemStateTests`, `AgentPlistTests`, `DozLocatorTests`, `CommandRunnerTests`, `AppInstallTests`, `MenuBarFlavourTests`, `AssembleAppTests`, `make test-cli-app`.
- **Opening another Mac's dashboard is a plain link to its origin: no token, cookie or link is ever passed, stored or shown; `macs.json` holds names and origins only.** Your Macs (`doz ui macs`, `MacBookmarks`) are bookmarks a person keeps — nothing is discovered; an ADDRESS becomes exactly one `scheme://host[:port]` (`MacAddress.origin`), and a sign-in link, query, fragment, path, login or this Mac's own dashboard is refused before anything is written, never repeated back; reachability is checked only when a person asks (`add`, `check`: `MacReachability`, one `GET /`, no cookie, no redirect followed, 3 s), never by the page, the daemon or a timer; the daemon never writes the file (web.md, "Your Macs"). `MacBookmarkTests`, `MacBookmarkStoreTests`, `MacReachabilityTests`, `make test-cli-macs`.
- **A workspace changes from the dashboard only by its brief, by filing loose agents and — this Mac's own browser only — by being created and started, by adding and ending its workers and by its lifecycle; no browser has any other workspace action.** The workspace actions are `workspace-brief` = exactly `workspace-edit` with the name, the brief and `ifBrief` (strictly decoded: never a reference, folder, manager or room), the three FILING actions, each exactly one HostOp the CLI sends: `workspace-adopt` `{workspace, agent, as?}` (`doz workspace adopt`), `workspace-new` (`doz workspace new`, the New workspace wizard's fields: `{workspace, brief, refs?, folders?, newFolder?, fromProject?, room?|noRoom?, manager?, managerIsolation?, workerIsolation?: fenced|vm, network?, adopt?: 0–4}` — never a project path or `noManager`; `fromProject` is filled on the Mac) and `workspace-release` `{workspace, agent}` (`doz workspace release`), and `workspace-start` `{workspace, actsAsYou?}` (`doz workspace start` with `confirmRequired`: the daemon refuses an unfenced manager the person did not confirm). Filing and starting are **this Mac's own browser only** (`WebAction.isFiling`/`isStarting`, `WebExposure.decideFilingAction`/`decideStartAction`: another computer gets 403 `mac-only` whatever `serve.chat` or `serve.mac_sessions` say — what a workspace holds decides what it, and its manager, may reach; `new` makes a room as you; `start` posts as you and hands a bot's token to a program, maybe an unfenced one acting as you), and so is the wizard's read-only plan route (`mac-screen`). The worker actions `worker-add` (`doz worker add`, every field the CLI takes; `isolation: unfenced` only with `confirm: "unfenced"` — the page's tick "It acts as you", never preselected) and `worker-end` `{workspace, name, confirm = name}` (`doz worker end`, never `--rm`) are each exactly one HostOp, this Mac's own browser only (`WebAction.isWorker`, `WebExposure.decideWorkerAction` → 403 `mac-only`: an add makes a participant and its token and starts a program, maybe one acting as you), and so is the Add a worker page's read-only plan route `worker-plan` (`mac-screen`). The eight lifecycle actions `workspace-stop`, `-sleep`, `-wake`, `-finish`, `-reopen`, `-archive`, `-restore`, `-delete` `{workspace, ifPlan, …}` are each exactly the CLI's HostOp, this Mac's own browser only (`WebAction.isLifecycle`, `WebExposure.decideLifecycleAction` → 403 `mac-only`: each stops, starts or removes what the workspace holds, archives its rooms as you or hands a bot's token to a program again), each acting only on the plan the page showed (`ifPlan`: changed since → refused, nothing done) with `confirmRequired`: archive and delete carry the name typed (`confirm`), checked by the daemon, and a wake of an unfenced manager needs `actsAsYou`; their plan route `workspace-lifecycle-plan` is read-only and `mac-screen`. The workspace-wide views read through three payload-less, read-only routes (`workspace-reach`, `workspace-folders`, `workspace-activity`: another computer sees held secrets only as a count and this Mac's sessions only with `serve.mac_sessions` on), and their one change beside the sandbox's `net-policy` is `mac-net-policy` `{session, grant}` = exactly `net-policy` with `@mac` and the session (`doz net allow @mac --session S site:HOST`), `site:` grants only (never a revoke, deny, preset or `host:` port), this Mac's own browser only (`WebAction.isMacNet`, `WebExposure.decideMacNetAction` → 403 `mac-only`, one audit line; `WebActionTests.testTheMacNetPolicyIsExactlyNetPolicyWithSitesOnly`, `ServeExposureTests.testMacNetIsThisMacsOnly`, `ServeHTTPTests.testMacNetPolicyIsThisMacsBrowserOnlyWhateverTheServeSettings`). Nothing on disk goes without its flag (`removeSandboxes`; `binFolders` — folders only to the Bin, a test's is `DOZ_TEST_TRASH_DIR`, never the real one). No `workspace-rename` is an action (the five `bot-*` changes are this Mac's own browser's, below). A space workspace's brief is its file: an edit writes `BRIEF.md` beside the space file (never the store's copy; `SpaceBriefFileTests`), under the same rules. Another computer reads the brief only with `serve.chat` read or write (403 `brief-remote`), edits it only with `write` (its announcement speaks as you; one audit line, never the text), and gets no line, row, gap or place about this Mac's sessions while `serve.mac_sessions` is off. `WebActionTests` (`testEveryActionIsExactlyOneAllowedHostOp`, `testTheWorkspaceBrief`, `testFilingALooseAgent`, `testTheNewWorkspaceWizardsActions`, `testTheWorkerActions`), `ServeExposureTests` (`testTheBriefFollowsServeChat`, `testFilingIsThisMacsOnly`, `testStartingAndPlanningAreThisMacsOnly`, `testWorkersAreThisMacsOnly`), `ServeHTTPTests` (`testTheBriefIsEditedFromAnotherComputerOnlyWithServeChatWrite`, `testServeChatWriteEditsTheBriefAuditedAsOneLine`, `testTheBriefFollowsServeChatAndTheLogHidesThisMacsSessions`, `testFilingIsThisMacsBrowserOnlyWhateverTheServeSettings`, `testCreatingAndStartingAWorkspaceIsThisMacsBrowserOnly`, `testWorkersAreThisMacsBrowserOnlyWhateverTheServeSettings`), `WebHTTPIntegrationTests.testTheWorkerPlanRoute`, `WorkerPlanTests`, `WorkspaceManagerTests.testConfirmRequiredRefusesAnUnconfirmedUnfencedManager`; the lifecycle: `WebActionTests.testTheLifecycleActions`, `ServeExposureTests.testTheLifecycleIsThisMacsOnly`, `ServeHTTPTests.testTheLifecycleIsThisMacsBrowserOnlyWhateverTheServeSettings`, `WebHTTPIntegrationTests.testTheLifecyclePlanRoute`, `WorkspaceLifecycleHostTests` (`testTheTypedNameIsCheckedByTheDaemon`, `testAnUnfencedManagersWakeFromABrowserNeedsTheConfirmation`, `testBinFoldersMovesToTheTestsBinAndRefusesTheStore`), `TestSafetyTests.testTheBinIsTheTestsOwnAndTakesOnlyAScratchFolder`, `make test-cli-workspace` rows L1–L14.
- **Participants change live only through the supervised control channel; the conformance gate is unchanged.** A participant added or removed, or a token replaced, is taken by the running chat server over the socketpair the daemon hands it (`--control-fd`, only with `--supervised` and `--token-hashes`; no signal, file or HTTP way — `doz chat serve` as the conformance runner starts it has none, SIGHUP still stops it with 0, the reference's `/invite` and `/remove` unchanged); `ChatReloadPolicy` restarts for anything else and when in doubt, and a reload must equal a restart on the same files (chat.md, "The control channel"). `ChatLiveReloadTests` (the differential test), `ChatReloadPolicyTests`, `ChatSupervisorReloadTests`, `make test-chat-conformance`, `make test-cli-chat` rows 35–40.
- **An export never carries a token, never follows a link, and copies only the session's own files.** Every file a chat or transcript export writes passes `ExportSweep` (a live chat token found by its hash, replaced, its owner named — never the value) into an `ExportFolder` (new or empty, outside the store, `O_CREAT|O_EXCL|O_NOFOLLOW`); a transcript is read with no link in its path (`O_NOFOLLOW_ANY` + `fstat`: regular, one link, yours, ≤ 64 MiB), and only the files the session's record names (carried `name:sha256`, recorded `claudeSessionIDs`) — a folder is never listed to find one. `ExportSweepTests`, `ChatExportTests`, `TranscriptCopyTests`, `make test-cli-chat` 41–45, `make test-cli-host` T1–T3.
- **Permissions constrain agents and never the owner; one decision; every HostOp is classified.** `PermissionGate.check` runs once at the top of `HostServer.serve`, before any routing, and a request with no `actAs` — every request today: the CLI on the owner's socket, every web action, the in-process core — is `.owner` and returns before any grant, ceiling or record is read (not even the owner's own nevers and ceilings bind the owner); `actAs` (the hidden `--as W/AGENT`) only narrows, a bad one is refused, never the owner's, and the in-process core never answers one. An agent's answer comes only from `GrantDecision.decide` (pure; `doz why`, `permissions show`, the gate and the Can do tab print its words); `ActionClasses.classify` places every HostOp (no default: a new op does not compile unclassified) and anything not in its table is Dozable's own — never for an agent. Grants live in `<store>/grants/`, a workspace's `permissions`, a bot's `ceilingAnswers` (workspaces.md, "Permissions"). `PermissionGateTests.testTheOwnerIsNeverGated` (every HostOp, every ceiling and an everywhere never), `ActionClassTests.testEveryHostOpIsClassified`, `GrantDecisionTests`, `WebActionTests.testEveryActionIsTheOwners`, `make test-cli-workspace` P5 (rows 12 on run as the owner under every never) and P6–P7.
- **Forgetting a session on this Mac is this Mac's own browser only.** `mac-session-forget` and `mac-sessions-forget-ended` (each exactly `session-forget`) answer another computer 403 `mac-only` whatever `serve.mac_sessions` says, and the dashboard's `mac-session-end` carries `onlyRunning`, so no browser forgets through End; the daemon carries back first and never forgets a running or a workspace's session. `WebActionTests.testTheForgetActions`, `ServeExposureTests.testForgettingIsThisMacsOnly`, `ServeHTTPTests.testForgettingIsThisMacsBrowserOnlyWhateverTheServeSettings`, `MacForgetTests`, `make dashboard-walk`.
- **Dozable never runs a program — git included — in a folder an agent writes in order to look at it** (its `.git/config` would run as you): what changed is a bounded walk by descriptor, no link followed, `.git` skipped, no `Process` (files.md, "What changed in a workspace's folders"). `WorkspaceChangedFilesTests.testNoProgramIsRunInTheFolder`, `make test-cli-workspace` V3.
- **Vendored peer code enters only by its pin and commit, is served as a tree only with its structural checks, and `import()` only through the compiler's table** (web.md, "Vendoring by peer commit"): a peer-commit package is admitted by its `PIN` and full commit (every file's sha in both, nothing unlisted, each licence, notice and index named and allowed), served flat only when it imports nothing, or as a tree (`/assets/vendor-<package>-<pin16>/…`, bytes unrewritten) only when every module, worker and stylesheet passes the structural checks — literal `./` imports of listed modules, `import.meta` only in `new URL` of a listed worker or style, no computed `import(`, `blob:` worker, `eval` or string timer — with inert sites only as the compiler's `vendorAllowances`, bound to their file's sha256; the page's lazy `import()`s are the table's literals, each once in its one module; nothing of the people or machines that built it (`Scripts/vendor-neutral-check.swift` with `DOZ_NEUTRAL_DENYLIST`, a list kept outside this repository). `WebModulesTests` (`testTheSpaceEditorShipsAsATreeAtItsPin`, `testTheCompilerAdmitsThePeerVendorOnlyAtItsPinAndCommit`, `testTheLazyImportsAreTheCompilersTable`), `WebSecurityTests.testTheSpaceEditorsTreeIsAVendorAssetOnlyWhenListed`, `make dashboard-walk` (pictures, space).
- **Names are never cut; a point is found by what a person types**: a restore point's name is
  stored as given, ≤ `RestorePoint.maximumNameLength` (64; longer is refused with the limit — names live
  only in meta.json, a point's directory is its id). `RestorePoint.resolve`: exact id, exact name
  (newest), else the ONE point whose id or name starts with it — several is an error listing them
  (`HostCore.resolvePoint`, used by the daemon and the CLI).
- **Check, then ask**: a confirming command resolves what it is about first — the sandbox
  (`requireSandbox`), the point (`resolvePointFirst`, then the question names name, id, when; the
  request carries the id), the image/template — so a `[y/N]` is never offered for what would fail. A workspace's lifecycle verb shows its plan first (`WorkspaceLifecycle.plan`: each agent's row, kept and goes, every refusal) and acts only on the plan you saw (`ifPlan`, its sha: changed since → refused, exit 3); `WorkspaceLifecycleTests`, `WorkspaceLifecycleHostTests.testIfPlanMismatchIsAConflictAndNothingIsDone`.
- **`exec` and `run` start an off sandbox**: `HostRequest.start` (the CLI sends it unless
  `--no-start`; an older client never does) → `ensureRunning(start:)` runs `lifecycle(.start)` (boot
  view, boot log, metrics); `ExecOutput`/`SessionOpened` carry `started`/`woke`/`bootMilliseconds`.
  `doz create --start`. `make test-cli-points` covers W25–W27.
- **Looking never starts the daemon.** Read-only commands answer from the store in-process
  (`HostCore(readOnly: true)`) unless a daemon runs — or a record says a VM was live when its daemon went
  away, which only a daemon can recover. A short request does not reset the idle clock; an open
  attach or stream does. 694: `daemon status` and `doctor` read the login item read-only (plist, `launchctl print`).
- **The attach relay adopts the session BEFORE it answers**, and the client sends what was typed ahead of its first connection once it reads that answer (keys typed right after `up` were lost
  otherwise — the first `test-cli` run). After that, keys for a held (sleeping) sandbox are dropped, never queued for a frozen guest.
- **One keychain item holds at most `Keychain.maximumSecretBytes` (1800)** (599i rc.2: `security -i` cuts an input line at
  ~4096 bytes; a 4.2 KB ChatGPT sign-in was stored TRUNCATED with rc 1 on a real Mac). `SystemKeychain.write` refuses
  more before `security` runs, reads the item back and deletes it unless it is the secret whole — never a partial item; the
  in-memory test keychains (`MemoryKeychain`, the tests' `FakeKeychain`) enforce the same limit. Store less, or use
  `KeychainChunks`. `RealKeychainLimitTests` checks the real keychain (`DOZ_TEST_REAL_KEYCHAIN=1`, a throwaway
  `doz-test-limit-*` item, always deleted); the fake OpenAI issues real-sized tokens (~6 KB with a 2.1 KB refresh token).
- **Dozable never holds, uses or writes Claude Code's refresh token, and never writes a
  `Claude Code-credentials*` item**. It reads the Mac login's ACCESS token only — from that Keychain item or (687),
  READ-ONLY, the same account's other store `<claude config>/.credentials.json` (a login over ssh refreshes only the
  file; `ClaudeMacLogin.choose`: the file only when unexpired, the later expiry when both are; a regular file, never a
  link; the refresh token parsed and dropped; `DOZ_TEST_CLAUDE_CREDENTIALS_FILE` in guarded runs, `TestSafety` stops one
  that would read the real file) and writes neither; the Mac's
  Claude Code is the one writer of that token family (a second holder forks it — a copied
  `.credentials.json` was rejected for this in an earlier project, and for its silent fall-through to API billing).
  Renewal is the Mac's: the only thing doz may do is run the Mac's own `claude -p` (the keep-alive, opt-in, `on|always`;
  never beside an UNFENCED Claude Code — github-and-access.md). Every secret doz writes to the keychain goes on `security -i`'s STDIN.
- **Never inject our credential beside the guest's own** (588: the prototype added the Mac's bearer
  token next to a guest `x-api-key`). Every auth header a daemon's bindings use counts as "a
  credential is present"; a connection that carried the guest's own credential gets nothing
  injected afterwards. `testNeverInjectBesideTheGuestsOwnCredential` and `make test-vm-claude`.
- **A foreign credential is a fingerprint, never a value** — 12 hex of sha256, kind, a prefix of at most 13 characters — in the log, events, `key ls` and `ls`.
- **Placeholders persist as sha256 hashes** (`doz.json` `placeholderHashes`, D8) so a session
  survives a daemon restart; `shutdown`/`reset`/`rm` revoke them. A stdin key is still memory-only:
  after a daemon restart a sandbox holding only one has no secret, and the proxy stops decrypting. A launch secret
  (692 `--secret`; network.md) has its own keychain item, re-read by a new daemon, deleted when revoked (shutdown/reset/
  rm/rename; a fenced record's removal); never a value in argv, a record, a log or the session. `LaunchSecretTests`.
  A bot's token lives only in its keychain item (never argv, a record, a log or `--json`); retired names stay reserved (`BotTokenTests`); the dashboard never carries, shows or stores a bot token: bot writes are this Mac's own browser only and `heldOnly` — anything that would make a token to show once is refused before the keychain or chat is touched, a bot elsewhere is the terminal's (`WebActionTests`, `ServeHTTPTests`, `BotTokenTests`, the dashboard walk's leak sweep); it reaches a session only as a bot-held launch secret (`LaunchSecret.bot`: never copied, never deleted with the session — `BotLaunchSecretTests`), and an unfenced manager's token file is 0600 in a 0700 temp folder, gone at stop. A worker's chat token is made by the daemon and held only as a launch secret of its place (or a bot's own item); never in argv, a record, a log or `--json`; revoked at `doz worker end` (`BotLaunchSecretTests.testADaemonMadeGrant`, `WorkspaceWorkerTests`, `make test-cli-workspace` rows 25 and 28).
  **Plain HTTP never carries a placeholder** but a launch secret's (all `secret:`, setting on, exact host AND port, to
  the route or Tailscale, every dialled address in 100.64/10). `PlainHTTPSecretRuleTests`, `EgressProxyPlainHTTPTests`.
- **No silent fallback between accounts.** A missing, expired or signed-out credential is
  answered by the proxy itself (401, an Anthropic-shaped JSON error Claude Code shows) with what
  to do — never another account's or an API key's. The account `mac` MEANS whoever is signed in on
  the Mac, so a Mac sign-in as someone else is followed, not held (owner, 2026-10-23: "this should be
  transparent to the sandboxes"): `LoginWatcher.freshen` (the vault's `onBeforeUse`, one `stat` of
  `.claude.json` at most once a second) re-reads on the next request, the new identity is pinned and
  said once. `testMacSignOutClearsAndADifferentAccountIsFollowed`.
- **What a person reads carries no internal numbers**: no feature numbers or walkthrough IDs in `--help`, setting descriptions, messages or the dashboard's strings — they belong in comments. `make docs-drift-check` runs `Scripts/user-text-check.swift` (and `Scripts/manual-check.swift` on `docs/manual`). Shell comments inside guest scripts are exempt: they are part of an image's recipe.
- **virtio-fs caches:** deleting a file on the DAEMON that the guest has cached is not visible at once — tests use fresh file names (this cost an afternoon of chasing a non-bug).
- **A run's archive lives in the store, 0700/0600, swept whole, and holds no token; no program runs to build it.** `<store>/archives/<workspace>/runs/<run>/` (and a room's `archives/<owner or _>/rooms/<room>-<id>/`) only, through `RunArchiveFolder` (no link in its path, each file `O_CREAT|O_EXCL|O_NOFOLLOW`, assembled in `.partial` and renamed); every file swept as written, then the whole archive again (any finding fails it), then the manifest, then every file re-hashed; commits are "not collected" (git would run a repo's config). `RunArchiveTests` (incl. `testNoProgramIsStartedToBuildTheArchive`), `ChatSliceTests`, `WorkspaceRunsHostTests`.
- **Nothing is removed before its archived copy is hash-checked.** A room's `rm` needs the room archived and a copy (its own, or its workspace's last run's) that holds every ordinary message and verifies NOW, the name typed, and the chat server's own check that the last seq did not move; a discarded conversation goes only while its sha256 (hashed through the descriptor it was opened by, `O_NOFOLLOW_ANY`) is the archive's `sourceSHA256` and its dev/inode are unchanged (`unlinkat`) — never a folder, a listing or another file. `RoomLifecycleHostTests`, `ChatClosedTests.testRemovalIsCheckedUnderTheLock`, `TranscriptDiscardTests`, `WorkspaceLifecycleHostTests` (`testDownArchivesFirstThenRemovesWhatTheRunMadeAndKeepsWhatPersists`, `testAFailedArchiveRemovesNothingContentBearing`). A space's `down` follows it: its scratch folders, rooms and discarded transcripts go only after their copy verifies, and nothing content-bearing goes when the run's archive failed. The ONE exception is a space file's `archive: off`: what goes with no copy is named in the plan, the summary and the confirmation ("deleted with no copy"), a room only while its last message is still the run's close, a transcript only against the hashes-only ledger written just before (`testArchiveOffIsTheOneExceptionAndIsNamed`).
- **A space file asks; the daemon decides.** The CLI reads the files and sends one merged document; the daemon never plans from a file and opens no named file but the two its record names — the brief and the space file itself (`SpaceRecordFile`: no link in its path, a regular file of yours, under your home, never the store, `~/.claude` or `~/Library`; written by temp-and-rename, only over the version read) — and acts only through its own operations, on the plan the person saw (`ifPlan`). `up` never writes a grant, a ceiling or `bots.json` (requests are recorded, never granted — `grants.json` byte-identical) and never writes the brief; an unfenced agent is never unfenced by inheritance: it is confirmed on a terminal at EVERY up, whatever set it, and the daemon refuses a confirm set that is not exactly the plan's. `down` never deletes a folder the space keeps (`--purge` releases it), removes a scratch folder only when its record names it and never in the store, and never touches an external. **Fenced memory reaches only the same agent's next fenced session**: captured into the store at down, seeded after the private folder is cleared, never into `~/.claude` or a shared folder; a non-persisted agent starts with none. Every new HostOp is Dozable's own. `SpaceUpHostTests`, `SpaceDownHostTests`, `SpaceMemoryTests`, `SpaceBriefFileTests`, `PermissionGateTests.testTheOwnerIsNeverGated`.
- **A space file is changed only in this Mac's own browser** (or with `doz workspace edit W --space-file F --if-match SHA` in a terminal on the Mac). `workspace-space-save` `{workspace, text, ifMatch}` is exactly its HostOp — never a path: the file is always the record's —, 403 `mac-only` for another computer whatever `serve.chat` or `serve.mac_sessions` say (`WebAction.isSpace`, `WebExposure.decideSpaceAction`; the file decides what the next up starts, where and with what access); it writes only over the version read (`ifMatch` hashed through the descriptor: changed since → refused, nothing written) and never runs up. Another computer reads the file and plans it (`workspace-space`, `-space-plan`) only with `serve.chat` read or write (403 `space-remote`), with `canSave` false; its `workspace-state` and frames show this Mac's agents only as `serve.mac_sessions` allows (`unknown`, "not shown to another computer"). SpaceState carries one chat text: an open Ask's question and option labels, live only, for this Mac's browser and the CLI, and for another computer only with `serve.chat` read or write. Frames never carry it (`SpaceStateFacts.dropMessages`), and a frame never a program's own message. `SpaceRecordFileTests`, `WebActionTests.testTheSpaceSave`, `ServeExposureTests.testTheSpaceRoutesFollowServeChatAndSavingIsThisMacsOnly`, `ServeHTTPTests` (`testTheSpaceFileIsSavedOnlyInThisMacsBrowserAndReadAsServeChatAllows`, `testTheSpaceFileIsReadRemotelyWithServeChatButNeverSaved`), `SpaceStateTests.testAnotherComputerSeesThisMacsAgentsOnlyAsServeMacSessionsAllows`, `WorkspaceLifecycleHostTests.testTheSpaceFileIsReadAndSavedThroughTheRecord`, `make test-cli-workspace` F3–F4. **A dirty space file is never left or reloaded without asking**: the space editor's page (web.md, "The space editor's page") holds a change of address with the router's leave guard (`setLeaveGuard`: the address put back, then Stay / Leave), asks on `beforeunload`, and a restart's reload waits (`pageIsIdle` reads `state.spaceDirty`); its text view is added to the mounted editor (`addFeatures`), never by a remount. `WebModulesTests.testTheSpaceEditorsPageAndItsAddresses`, `make dashboard-walk` (space 5).
- **Closing, archiving and removing a room are the owner's, only through the control channel, and this Mac's own browser only.** The closed set (rooms of finished workspaces — finish closes its rooms; reopen opens them) and `roomRemove` reach the chat server only over the supervised control channel (no route, file or slash command; the reference's refusal status kept; `reason` only with `chat.refusal_reasons`; conformance unchanged); `chat-room-archive`, `chat-room-rm` (never `--loose`) and `workspace-run-archive` are each exactly one HostOp, 403 `mac-only` for another computer (`WebExposure.decideRoomAction`), `chat-room-plan` `mac-screen`. `ChatClosedTests`, `ChatSupervisorReloadTests`, `WebActionTests.testTheRoomActions`, `ServeExposureTests`, `make test-chat-conformance`, `make dashboard-walk` (life 4).
- **Only the owner makes a decider, and an ask fails closed.** The decider role is given only by `doz chat set NAME --role decider` on this Mac (the gate refuses an agent's `chat-set` that carries roles, whatever it holds; a bot's role is checked at naming AND at deciding; a person needs none); every ask can be declined and expires to decline, a closed room expires its open asks at once, a refused decision is never written into the room, and the first decision wins under `askLock` — the lock order (close gate → `askLock` → the core's lock → the expiry index) is never inverted (chat.md, "Asks"). `PermissionGateTests.testOnlyTheOwnerGivesTheDeciderRole`, `ChatAskDecideTests`, `ChatAskLifecycleTests`, `ChatAskLockOrderTests`, the conformance gate (section 13, `-ask`), `make test-cli-chat` A1–A10. **Dozable never speaks for an agent, and an ask is answered in this Mac's own browser only:** `chat-ask`, `chat-decide`, `chat-withdraw`, `chat-asks` are one fixed call each on the owner's socket as you (a decision once per `actionID`); a request made as an agent (`--as`) that the gate allows is still refused — an agent asks and answers with its own token (dozchat). The decision card answers only through `core/asks.js` and the action `chat-decide` (exactly that HostOp), 403 `mac-only` for another computer whatever `serve.chat` says (`WebAction.isAsk`, `WebExposure.decideAskAction`); the answer's text never in an operation's label or line, `ui.operations.json` or `ui.log`, and never repeated in a refusal (chat.md, "Asks"; web.md, "Chat"). `PermissionGateTests.testAnAgentNeverAnswersThroughTheDaemon`, `ChatAskHostTests`, `WebActionTests.testTheAskDecision`, `ServeExposureTests.testAnsweringAnAskIsThisMacsOnly`, `ServeHTTPTests.testAnAskIsAnsweredOnlyInThisMacsBrowserWhateverTheServeSettings`, `WebModulesTests.testTheAskCardAndItsOneAnswerPath`, `make test-cli-chat` D1–D14, `make dashboard-walk` ask 1–7.

## Engineering docs — read the one for the area you touch

Each holds one area's rules and its full code map. The rules above apply to every change; an area's own rules
are in its doc, so read it before changing that area.

- [docs/engineering/engine.md](docs/engineering/engine.md) — the `Sandbox` actor, the lifecycle planner, VZ, disks and restore points, the kernel, deckhold, the daemon and its client, the CLI, settings' code, the VM suite; a daemon stop's progress, the guest's time zone
- [docs/engineering/network.md](docs/engineering/network.md) — subnets, `NetworkPolicy`, the egress proxy and NIOSSL, the credential vault and the CA, doznet, web ports and sign-in from Open, a model server on this Mac
- [docs/engineering/images-and-bases.md](docs/engineering/images-and-bases.md) — image specs and bakes, Claude Code's launcher, agent tools and versions, an image never rebuilt without the user, Resources, base × agent images, agent permissions
- [docs/engineering/github-and-access.md](docs/engineering/github-and-access.md) — the Mac's Claude Code login and accounts, agent credentials per agent, GitHub as the user, the Access step
- [docs/engineering/codex.md](docs/engineering/codex.md) — Codex as an agent: its launcher, accounts, Dozable's own ChatGPT sign-in, the refresh, the proxy, the guest's auth.json
- [docs/engineering/recipes.md](docs/engineering/recipes.md) — agent recipes and key providers, the recipe catalogue and community recipes, model sources, network profiles, `doz try` and Quick try
- [docs/engineering/web.md](docs/engineering/web.md) — `doz ui`: the security rules, routes, actions and operations, the page's modules and style, the installable dashboard and restarts, the sandbox pages, browser terminals
- [docs/engineering/lan.md](docs/engineering/lan.md) — `doz ui --lan`: admission, devices and invites, where it listens, sandboxes never reaching it
- [docs/engineering/terminal-tui.md](docs/engineering/terminal-tui.md) — what the CLI draws: the colour switch, `Style`, components, `Prompter`, the input seam
- [docs/engineering/onboarding.md](docs/engineering/onboarding.md) — image preparation in the daemon, `onboarded.json`, the setup wizard, the environment prompt, `doz_project.yaml`, `doz init`, uninstall
- [docs/engineering/sessions.md](docs/engineering/sessions.md) — saved screens and the kept layout, boot logs, the session bridges (OSC 52, the browser bridge, tmux, the Ctrl-] menu, the folder's files), OSC 7501, painted thumbnails
- [docs/engineering/updates-and-release.md](docs/engineering/updates-and-release.md) — `BuildFlavor`, anonymous usage statistics and the sign-up, the signed update feed and channels, `make release`, signing, Homebrew
- [docs/engineering/workspace-rules.md](docs/engineering/workspace-rules.md) — `.dozignore` / `.dozreadonly`: `dozview`, Docker's semantics in C and Swift, modes, the wake
- [docs/engineering/tools-and-dotfiles.md](docs/engineering/tools-and-dotfiles.md) — the tools layer (gh, tmux 3.8, …) and the person's dotfiles
- [docs/engineering/files.md](docs/engineering/files.md) — the file watcher (`files-list`, `doz files`, the files routes) and the Files tab's changes, Open in an editor
- [docs/engineering/sound.md](docs/engineering/sound.md) — `sandbox.audio`, the sound kernel (GPL-2.0, ours), the microphone's permission
- [docs/engineering/chat.md](docs/engineering/chat.md) — the chat server: no VM parts, isolation, the strict config, the access rules and `agent_addresses`, the protocol's bytes and store, the conformance gate
- [docs/engineering/menu-bar-app.md](docs/engineering/menu-bar-app.md) — Dozable.app: the doz command as its only interface, the menu's state table, refresh, `doz app install`, the seams
- [docs/engineering/workspaces.md](docs/engineering/workspaces.md) — workspaces: the record and its store, the derived state, adopting agents, the main room in chat, the manager (the set-up check, start and stop), workers (add, the token kinds, a shared sandbox, end, the sweep); Agents / Bots and their tokens

## Verifying changes

```bash
make build     # swift build — Xcode 27 needs the --build-system native pin the Makefile probes for
make test      # unit tests: no VM, no entitlement. Never --parallel. (web-assets-check first)
make web-assets        # 590: regenerate Sources/DozableWeb/Resources/Web after editing WebSource/ (commit it); make css-lint (647, in make test): the stylesheet's rules; make css-perf: its cost in headless Chrome; make dashboard-walk: the shell (Home, the sidebar, every old address, This Mac), a workspace's page and agents, Agents / Bots and its leak sweep (no token in the DOM, network, console, storage, files or ps), the New workspace wizard, Add a worker (a FAKE claude), the isolation guide and a workspace's lifecycle dialogs in headless Chrome, scratch store and profile
make audit     # Scripts/audit.sh
make test-vm   # the VM integration suite — see below
make cli       # 585: build + sign .build/debug/doz
make test-cli  # 585: the signed doz from separate processes, scratch store $TMPDIR/doz-clitest-store
make test-vm-claude  # 588: Claude credentials through the proxy with a FAKE key (DOZ_TEST_CLAUDE_LOGIN=1 adds this Mac's login, read-only)
make test-vm-upgrade # 591: the previous release sleeps sandboxes, this build wakes them; the in-place overwrite incident (scratch store $TMPDIR/doz-upgrade-store)
make test-vm-templates # 593: templates and duplicates on pi — no state disk in a template; duplicate's folder and fresh/copied state disk
make test-cli-onboarding # 594: test-cli's onboarding part alone (onboard, a joining start, detach/cancel, init/up, the agent prompt, uninstall)
make test-cli-bases  # 596: base × agent — cli, Dockerfiles via a fake container, the real container build (SKIPs unless Apple's services run; BASES_START_BUILDER=1), the VM matrix (BASES_PARTS=…)
make test-cli-permissions # 597: agent permissions — net show/allow/deny/permissions, create --allow, Claude Code's hosts reached under Standard, suggestions, live changes, facts, stored by name (prepares claude-code; network)
make test-cli-points # 594 W25–W27: point names/lookup, check before asking, exec/run start an off sandbox; make test-cli-timezone (W10): the Mac's (stubbed) zone at boot and every wake, or sandbox.timezone
make test-cli-host   # sessions on this Mac (@mac), no VM: the real deckhold-mac, harmless programs only; make test-cli-bots: Agents / Bots, the leak sweep; make test-cli-macs: Your Macs (doz ui macs) against a second scratch doz ui; make test-cli-workspace: workspaces, their manager and their workers (a FAKE claude, fenced and unfenced, the leak sweep), their lifecycle (sleep, wake, finish, reopen, archive, restore, delete; a scratch Bin); -vm: scratch lab VMs, a worker sharing a sandbox
make test-cli-keychainlocked # a daemon started where the login keychain is locked (DOZ_TEST_KEYCHAIN_LOCKED): warned, named by account ls and doctor, never always on, a locked restart refused, replaced by the login item's look, never runs the keep-alive (no VM); make test-cli-alwayson: on by default, off at once, restarted in place after an install; make test-cli-daemon: the login item, no VM, a scratch LaunchAgents folder + a FAKE launchctl (never the real ones) — rows 1–12 in engine.md
make test-cli-exectimeout # exec --timeout from doz's start, 124 from the daemon: the command killed, a start/wake that outlasts it goes on, a stopped client
make test-cli-agentsudo # 594 W23: the agent's sudo in a fresh claude-code sandbox (prepares it; network), --no-agent-sudo, the setting at the next boot, root reaches no more
make test-recipe-catalogue # 652: the recipe catalogue end to end — publish (throwaway key) into a DIRECTORY_DIR (CNAME, .nojekyll, index.json; the update site refused) → a local server standing in for doz.sh → the daemon's refresh → the next start uses it; doz.sh/… names resolve with no request; tampered refused
make test-community-recipes # 653: your own recipes and community catalogues end to end (throwaway keys, a local server): check fails then passes, labels, Dozable's id refused, confirm before fetch, a clash refused whole, tampered refused, removal keeps a sandbox
make recipe-check RECIPES=all # 617: every recipe for real — build, verify, a fresh try, its check turn against a stand-in provider, keys, leak guard, OSC 7501 states (report: $RECIPE_STORE/report.json)
make test-cli-codex # 599i: Codex through seams (a fake OpenAI over TLS, the browser seam): Dozable's own ChatGPT sign-in, the swap, the Mac's renewal, no token in the guest, an API key, Alpine (prepares codex + alpine-codex)
make test-cli-github # 599d: GitHub as the user through seams (a fake GitHub, a fake gh, a throwaway ssh-agent): swap, read-only, push, no leak, identity, key source, off, SSH
make test-cli-openfiles # 599b: the folder's files opened on the Mac through the opener seam — every refusal, isolated, off, --app, URLs as before
make test-cli-dotfiles # 657: your dotfiles in real VMs — local scratch repositories, the install script and the link pass, Dozable's own untouched, trust refused off a terminal, --update, never applied twice (prepares claude-code)
make test-cli-files  # 643: doz files — listed/watched on the Mac (no daemon, rules, a link out refused, nothing woken); isolated listed inside while running
make test-vm-cwd     # BUG cwd-after-wake: a program's cwd in /workspace across sleep, hibernate and a new-process restore (the raw share as the control); the passthrough view's cost
make test-vm-ignore  # 599g: folder rules (.dozignore lock/hide, .dozreadonly) across boot/pause/sleep/hibernate/new-process restore, reload, folding, kills (scratch store); then test-vm-agentwrite (also alone, and run by test-vm-cwd): the agent (a non-root image user) writes shared folders through the view
make dozview / dozview-verify / tmux / tmux-verify / dozchat / dozchat-verify # rebuild the guest view daemon / tmux 3.8 / the chat client dozchat (pinned Zig) / check the committed bytes; dozchat-mac, dozchat-check (ASan+UBSan, fuzz)
make sound-kernel    # 667: build the sound kernel from source (twice, a throwaway ubuntu VM, network, ~7.5 min) and check it is SoundKernel.sha256 (SOUND_KERNEL_OUT)
make test-cli-tmux38 # 658: Dozable's tmux 3.8 on Debian + Alpine (prepares both): the bridges through it, the theme reported, OSC 7501 measured, an older distro tmux session kept and ended
make deckhold / deckhold-verify / deckhold-snapshot-check # the guest PTY holder: rebuild (pinned Zig + ghostty) / check the committed bytes / 610: its snapshot equals its screen, cell by cell
make deckhold-mac / deckhold-mac-check # deckhold built for THIS Mac (sessions on the Mac; not committed, shipped beside doz in the CLI tarball only) / the status, grid, snapshot checks + mac-smoke.sh
make deckhold-status-check / deckhold-grid-check # 612: the OSC 7501 consumer (the query, the records' rules and limits, invalid input, every cut offset + a fuzz) / 648: the GRID (each row's text is the holder's screen, colours/flags/cursor, the gen, the limits, + a fuzz)
make test-cli-grids  # 648: session-grids through a real daemon — a coloured session's grid, unchanged/moved gens, asleep stays asleep with a saved grid, no daemon starts nothing
make test FILTER=Suite # the matching unit tests only (swift test --filter)
make test-cli-startup  # the cost of a start: ls/sessions/exec/attach build no recipe part (DOZ_TEST_STARTUP_TRACE=1); doz ls --json median <= 60 ms, <= 1 s under taskpolicy -b; doctor's priority warning; a daemon started from the background leaves it (scratch store, no VM)
make test-vm-status  # 612: a FAKE agent's status through deckhold, the daemon and the CLI — no viewer and a viewer, sleep/hibernate + wake, the exit, shutdown (scratch store)
make test-cli-hoststop # 594 W22: test-cli's host-stop part alone (per-sandbox progress plain/animated, --json, nothing running, a daemon killed mid-stop); make pullbench (D12): 3 vs 6 concurrent layer downloads
make app / test-cli-app # the menu bar app: .build/debug/Dozable.app, ad hoc, never opened / its non-GUI modes against the real doz and fakes, doz app install --dest a scratch folder, --launch-daemon, Start at Login through the recording service and a fake launchctl (no VM, no screen, nothing registered)
```

### Test safety is the default

Every `make test*` target (and the probes' `guard-doz.sh`) runs with `DOZ_TEST_GUARD=1`, `DOZ_TEST_NO_MAC_LOGIN=1`, `DOZ_TEST_CREDENTIALS=memory`,
a scratch `DOZ_TEST_CODEX_HOME` and a scratch `XDG_CONFIG_HOME` whose `doz.toml` sets `store.path` and `defaults.projects_dir` to scratch
folders — forced, whatever the environment says (694: a scratch `DOZ_TEST_LAUNCH_AGENTS_DIR`, a refusing `DOZ_TEST_LAUNCHCTL`; a scratch `DOZ_TEST_APPLICATIONS_DIR`). `TestSafety`
STOPS a guarded process (and any XCTest run) that would use the default store, read the Mac's real `~/.codex`, touch the keychain's `Claude
Code-credentials*` items, the real `~/Library/LaunchAgents` or `/bin/launchctl`, install the menu bar app into `/Applications` or `~/Applications`, ask macOS to open an app (`DOZ_TEST_APP_OPEN_LOG` records it; a "running copy" is a stand-in outside any bundle, `DOZ_TEST_APP_STANDIN`), or run any keep-alive claude but the fake `DOZ_TEST_CLAUDE_BIN` (695). The only way out is explicit: `DOZ_TEST_REAL_MAC=1`.
A new code path that reads something of the Mac's own must go through a seam the Makefile sets (`CredentialServices.forHost`, `macLoginKeychain`) — `TestSafetyTests` pins the decisions.

**Paths are SHOWN with `~`** (617): `DisplayPath` (DozableHost: `tilde`, `tildeIn`, `homes`) and its twin `core/paths.js`
(`tildePath`, `tildeIn`, fed the session info's `homes`) are the ONE way a Mac path is shown — the sidebar's store, the
try banner, the Guide's facts, the details' folder, a Dockerfile, the plan's lines, Doctor, and the CLI's human lines
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
