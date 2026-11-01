# The engine and the host

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

A bare file name is in `Sources/DozableKit/`.

| Path | What |
|---|---|
| `Sources/DozableKit/Sandbox.swift` | The `Sandbox` actor: boot (images, golden-disk bake, APFS clone, VM), lifecycle via the planner, exec, sessions/attach |
| `Phase.swift` | `Phase` and `LifecyclePlanner` — each operation's steps as DATA (incl. stop / resetToImage / delete), so the invariants are unit tests |
| `VirtualMachine.swift` | Direct VZ ops; `PinnedIdentity` (machine id + MAC); `DozableVMM`, `AdoptingInstance`, `AdoptingAgent` — restore into a new process |
| `SessionConnection.swift` | One viewer's connection: HELLO/DATA/RESIZE out, SNAPSHOT/DATA/EXIT in; never delivers or sends after close |
| `DeckholdProtocol.swift` | Frame codec, `deckhold ls` parser, `GuestCommand` (every guest argv; the share re-mount script) |
| `StoreLayout.swift` | Storage layout under `storeRoot`; `PersistedSandbox` (what a new process needs to restore) |
| `DeckholdBinary.swift` | Finds the resource without `Bundle.module` |
| `EXT4Inspector.swift` | an ext4 image FILE read on the host — `has_journal`, clean state, the free-block bitmaps (== `dumpe2fs`'s list) |
| `DiskAccounting.swift` | per-disk unique / shared-with-parent / garbage / extents from APFS's extent map (`F_LOG2PHYS_EXT`), PRIVATESIZE cross-check; range helpers |
| `Maintenance.swift` | `reclaim()`, `rederive()`, `maintenanceAdvice()` (586's thresholds), `checkDisks()` — stopped sandboxes only |
| `RestorePoints.swift`, `FsckHelper.swift` | Restore points, custom images; e2fsck of a running-taken copy in a helper VM (on the file, over virtio-fs) |
| `KernelProvider.swift` | The pinned Linux kernel (`KernelArtifact.recommended`): override → verified cache → byte-identical seed → download + verify archive + extract + verify kernel |
| `Resources/deckhold` | The committed static aarch64-linux-musl guest binary — see `Guest/deckhold/PROVENANCE.md` |
| `Guest/deckhold/` | deckhold's C source, `build.sh` (pinned Zig 0.16.0 + ghostty `b988efc`), `PROVENANCE.md` |
| `Sources/doz-vmtest/` | The VM integration suite (entitled executable); `NetworkSuite.swift` is `network`; `CLISuite.swift` is `cli` (`make test-cli`); `ClaudeSuite.swift` is `claude` (`make test-vm-claude`) |
| `Sources/DozableHost/HostProtocol.swift` | the host protocol (JSON lines, `HostOp`, results) — fields only ever added |
| `Sources/DozableHost/HostCore.swift` | the host's model — every sandbox as a `Sandbox`, every operation, crash recovery, metrics rows; also used read-only in-process |
| `Sources/DozableHost/HostServer.swift` | `doz host` — the lock, the socket, the attach relay (held clients), streams, idle exit, quit = Hibernate |
| `Sources/DozableHost/HostClient.swift`, `UnixSocket.swift` | the detached-child launcher, the client, socket plumbing, `ClientWire` (SandboxLab's attach wire) |
| `Sources/DozableHost/DozableStore.swift`, `Metrics.swift` | the CLI store's files, `SandboxConfig` (`doz.json`), images → specs; the metrics DB (SandboxLab's schema) |
| `Sources/DozableCLI/` | the commands (ArgumentParser), the attach client, `doctor`; `UICommand.swift` (`doz ui`, `ui link`) |
| `Sources/DozableHost/Settings.swift`, `TOML.swift`; `Sources/DozableCLI/ConfigCommands.swift`; `Sources/DozableWeb/WebSettings.swift` | 591 settings: the CLOSED schema (`DozableSettings.schema`), `${XDG_CONFIG_HOME:-~/.config}/doz/doz.toml` generated from it, our own strict TOML subset (no dependency), precedence flag > env > file > default with a source per value; `doz config`; the UI's Settings page route (`GET`/`POST /api/v1/settings`) |
| `Tests/DozableKitTests/` | Unit tests — no VM |

## Rules that each cost a bug to learn here

- **A host stop shows its progress** (`HostStop.swift`): `host-stop` streams, per sandbox, a
  `started` "hibernating X" and a `step` "hibernated X (snapshot …)" / `failed` (why + "shut down
  instead") — `HostEvent.startedAs` ties an end to its differently-worded start — then the host's own
  last step, and answers `HostStopResult` (rows; an older host answers the string "stopped", still
  read). `Sandbox.prepareForExit` returns its `ExitOutcome`. Every stopping client uses
  `stopHostShowingProgress` (the CLI's progress view: animated on a tty, plain lines else) or, in the
  UI, Restart host's operation (`WebOperation.lines`). A host that dies mid-stop: the client reports
  what it saw (`HostStopView.seen`), never hangs. `make test-cli-hoststop` (in `test-cli` too).
- **The sandbox follows the Mac's time zone**: `GuestTimeZone` — the zone's TZif bytes from
  THIS Mac's `/usr/share/zoneinfo` (portable to glibc and musl; the Alpine lab has no tzdata) — written to
  `/etc/localtime` (+ `/etc/timezone`) by `prepareGuest` at every fresh boot and by `.resyncClock` at
  every wake (best effort; no new planner step). The host sets it (`HostCore.guestTimeZone`: the setting
  `sandbox.timezone` = `mac`, read NOW with `NSTimeZone.resetSystemTimeZone()`, or a zone) at adopt,
  every named request and every `ensureRunning`. The facts say it (`sandbox.timezone`).
  `DOZ_TEST_MAC_TIMEZONE` (a name, or a file holding one, read at each look) stubs the Mac's zone;
  `make test-cli-timezone`.
