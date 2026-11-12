# Sessions: saved screens, boot logs, bridges, status

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableKit/SavedScreens.swift`; `Sources/DozableHost/TerminalLayout.swift`; `Sources/DozableWeb/WebSessionMemory.swift` | 593 §9: the sessions' saved screens (`<sandbox>/screens/NAME.{vt,txt,json}`; the capture is `Sandbox.captureScreensLocked`, the `.captureScreens` step); the web UI's terminal layout kept by the host (`terminal-layout.json`); their web projections and the layout's strict decoder |
| `Sources/DozableHost/BootLogs.swift`, `BuildLogs.swift`; `Sources/DozableWeb/WebBootLogs.swift` | each sandbox's kept boots (`<sandbox>/boots/`), the recorder, the one renderer; 617: each image's last build log (`<store>/build-logs/`); the web's Boot log and build log projections |
| `Guest/deckhold/deckhold.c` (`ps_*`), `Sources/DozableKit/ProgramStatus.swift`; `Sources/DozableHost/SessionStatus.swift`, `HostCore+Status.swift`; `Sources/DozableWeb/WebSource/app/components/agent-status.js`; `Sources/doz-vmtest/StatusSuite.swift` | 612: what the agent is doing (OSC 7501) — deckhold's consumer (answers the query, keeps the records, WATCH/STATUS), the parsed record, the host's model + watchers + events, the page's chips and notices; `make test-vm-status`, `make deckhold-status-check` |
| `Guest/deckhold/deckhold.c` (`send_grid`), `Sources/DozableKit/ScreenGrid.swift`; `Sources/DozableHost/HostCore+Grids.swift`; `Sources/DozableWeb/WebGrids.swift`; `Sources/doz-vmtest/GridsSuite.swift` | 648: painted thumbnails — deckhold's GRID (the screen as cells, from libghostty-vt's render state), its decoder and the contract (`ScreenGrid`, inert text), the host op `session-grids`, `POST /api/v1/grids`; `make deckhold-grid-check`, `make test-cli-grids` |

## Typing into a session and its screen now (`doz sessions send` / `screen`)

`Sources/DozableKit/SessionInput.swift` (keys, frames, receipt, `LiveScreen`), `Sandbox.sendInput` / `liveScreen`,
`Sources/DozableHost/HostCore+SessionInput.swift` (ops `session-send`, `session-live`), `SessionsSend` / `SessionsScreen`
in `SessionCommands.swift`; `SessionInputTests`, `SessionsSendCommandTests`, `make test-cli-sessionsend` (also run by
`make test-cli-sessions`).

- **The acknowledgement needs no deckhold change.** deckhold handles one client's frames IN ORDER (`client_frames`):
  DATA goes to the program's input buffer, QUERY is answered with one INFO line. So a send is ONE `deckhold pipe` with
  DATA frames (≤ 16 KiB each, ≤ 64 KiB in all) then QUERY, its stdin KEPT OPEN until the INFO frame arrives
  (`pipe_mode` stops relaying at stdin's EOF) — the INFO frame proves every byte before it is in the buffer.
  NOSESSION → no such session (exit 2), EXIT → it ended (exit 2). It proves arrival, not that a TUI acted on it:
  `--then-screen[=MS]` reads the screen back in the same call.
- **The text, each key and Enter are separate writes** (`SessionInput.pieces`, `HostRequest.inputPieces`; the host
  splits an older client's trailing CR off too), `SessionInput.settle` apart (60 ms + 4 ms a KiB, ≤ 0.5 s), one QUERY at
  the end. In one burst a TUI takes everything as a paste: Claude Code kept the CR of `--text <236 bytes> --enter` inside
  its input box and never submitted. `test-cli-host` and `test-cli-sessionsend` check it with a raw-mode program that
  prints the size of each read (the Enter must be a read of its own; a CR inside `--text` is the control).
- **A send wakes, never cold-starts** (an off sandbox has no sessions: exit 3; `--no-wake` on a sleeping one: exit 3),
  waits for the wake's background steps (`afterWakeSettled`) and gives the memory balloon back first (input is work).
- **`screen` is read-only**: answered in-process with no host (the saved screen), never wakes unless `--wake` (then it
  needs the host). Running: `deckhold dump`, bounded like every listing read (`guestRead`: an unresponsive guest gets
  its saved screen, `reason: unresponsive`). Plain output is the rows only — the dump's `cursor=… size=… screen=…`
  line is parsed into `--json`'s `cursorX/cursorY`, `cols/rows`, `screen` (`primary`/`alt`), with the host's status.

- **`doz sessions wait`** (`session-wait`, `HostCore+SessionWait.swift`) opens a WATCH connection of its own (the
  holder answers with the status now, then each change) and returns at the first state in `--until`; done/error that
  outlive the program count (the host's kept status); the program ending first is exit 2; the timeout (at most a day,
  whatever is asked — a client that left must not leave a watcher) answers `timedOut`, exit 124. Never wakes.

## Sessions on this Mac (`@mac`)

`Sources/DozableHost/MacPlace.swift` (the name, refusals, the socket folder's rules), `MacSessions.swift` (records,
open, end, adopt, screens), `MacSessionsEnvironment.swift` (the allowlist), `HostCore+Mac.swift` (routing),
`HostServer.attachMac`, `Sources/DozableKit/DeckholdSocket.swift` (the transport), `Sources/DozableCLI/MacCommands.swift`;
`MacPlaceTests`, `MacSessionsEnvironmentTests`, `MacSessionsRecordTests`, `DeckholdSocketTests`, `make test-cli-host`.

- **A place, never a sandbox.** `HostCore.perform` routes `@mac` to `performMac` FIRST — no `Managed`, no `Sandbox`, no
  proxy, no placeholders; `MacPlace.operations` are the session ops; everything else is `MacPlace.refusal` (host side)
  and `MacCLI.refusal` (the CLI's entry, for a command that names `@mac` before `--`).
- **The holder is `deckhold-mac serve`** (`MacDeckhold.locate`), started by `posix_spawn` (SETSID, CLOEXEC_DEFAULT,
  signals default, stdin /dev/null, stdout+stderr `<store>/mac-sessions/NAME.log`, cwd `--workdir`) — never `sh -c`.
  `serve` daemonises (its child's parent becomes launchd) and returns once its socket listens: holders outlive the
  host by design. No session keeps the host alive.
- **The socket folder** is `confstr(_CS_DARWIN_USER_TEMP_DIR)` + `dh-<8 hex of sha256(store path)>` (never `$TMPDIR`):
  made 0700 and `lstat`-checked on every use (a folder, not a link, ours, 0700 — else nothing is read or made). Names
  ≤ 32, every path < 104 bytes. `Workspace.refusal` refuses it (and anything holding it) as a workspace.
- **The DeckholdSocket transport** speaks the frame protocol straight on the socket: one reader thread, a writer task,
  the descriptor closed ONCE by the reader after the writer let go. A socket that is gone answers as `deckhold pipe`:
  EXIT from `NAME.exit`, else NOSESSION.
- **Records** (`<store>/mac-sessions/sessions.json`, 0600): argv, workdir, environment NAMES, openedAt, holder sha256,
  pid, `bypassed`. A host start ADOPTS (`MacSessions.adopt`): a live socket is watched (statuses, `session-status`
  events under the place name `@mac`); a socket nothing answers is unlinked (only our own socket, in our folder); a
  record with no socket is ended (its `.exit`) or **gone** (rebooted, holder killed). Looking reads the folder
  in-process — no host.
- **The environment is an allowlist** (`MacSessionsEnvironment.build`), never the host's passed on; `PATH` from the
  login shell once (a guarded run never runs it: `DOZ_TEST_MAC_PATH`, else path_helper's list); `-e` refuses only
  `CLAUDECODE` / `CLAUDE_CODE_*`. `DOZ_TTY` in a session is deckhold's own.
- **End** is HUP → TERM → KILL of the program's group (the pid its holder names, still that group). **Restart** opens
  again from the record; `claude` without `--fresh` gets `--continue` (the record keeps the argv as opened).
- **Bypass**: allowed only when the session's own argv asks (`MacPlace.bypassesPermissions`), recorded and marked; never
  added.
- **Bridges**: OSC 52 as for any session; the open-URL and workspace-file markers are dropped (`HostCore.bridge`).
- **Saved screens** in `<store>/mac-sessions/screens` (`SavedScreens`' directory variants): the periodic capture and a
  host stop; an ended session has none; a gone one keeps its last — what `screen` shows, said "gone".
- **Host stop / uninstall / nuke**: stop says how many keep running (`HostStopResult.macSessions`); uninstall asks
  whether to end them; nuke ends them and removes the socket folder.

## Session memory and saved screens

- **Saved screens exist ONLY for a sandbox one wakes back into** — paused, asleep, hibernated.
  A SHUT-DOWN sandbox shows no session screens anywhere: shutdown, reset, rm and a host that died with
  the VM (`recoverAfterStart`) DELETE them (`.removeSavedScreens`; the host also clears the terminal
  layout on shutdown, reset and death), `sessions`/`session-screen`/`inspect` list nothing for it, and
  the page shows the plain off state (its panes close, none is persisted, no grid tile). There is no
  "ended" screen: a session whose program exited has none (the next capture removes it).
- **Screens are saved while the guest can still answer**: `.captureScreens` is the FIRST step of
  pause, sleep and hibernate from RUNNING (planner data — `LifecycleTests`); never a shutdown, never
  from another phase (the guest cannot answer). It is best effort and bounded (3 s a session, 8 s in
  all): a failure keeps the previous file and is a note — it never fails or holds up the lifecycle
  action. Quit = Hibernate captures too.
- **A capture is a momentary attach that disturbs nothing**: `deckhold pipe` as a non-terminal
  exec, written `DeckholdFrame.captureRequest` in one go — HELLO **0×0** (keep the session's size:
  no SIGWINCH, no reflow) then DUMP — read until DUMP's answer (then stdin closes and the pipe exits),
  and always `delete()`d. Nothing is typed; no focus report is sent. While attached (milliseconds)
  deckhold counts it as a viewer, so it does not answer a program's terminal query itself — accepted.
- **Stored as text, not an image**: `NAME.vt` (the SNAPSHOT: VT that redraws the screen, capped at
  2 MiB keeping the newest lines after a soft reset), `NAME.txt` (DUMP's text, every control
  character removed — what the CLI prints) and `NAME.json` (`SavedScreenInfo`). 648: and `NAME.grid.json` (the screen
  as cells, `ScreenGrid` — what a tile paints in colour; `SavedScreenInfo.grid`, `SessionScreen.grid`, `WebSavedScreen.grid`)
  when the holder's `ls` line announced GRID (`grid=1`): the capture is then HELLO 0×0 + GRID 0 + DUMP
  (`captureWithGridRequest`) — never to an older holder, which would drop the capture at the GRID; a capture without
  one REMOVES an earlier grid (never older than the text beside it); validated again when read. 0600 files in a 0700
  `screens/`, written atomically, and never into a sandbox directory that is gone. A capture drops the
  screens of sessions the guest no longer runs. Duplicate, fork, restore points and templates copy
  disks BY NAME — never the screens (`SavedScreensTests`).
- **The periodic capture** (`host.screen_capture_minutes`, 5; 0 = off; read at host start): each
  running, not-busy sandbox — ONE `deckhold ls`, then an attach only for sessions whose `bytes=`
  moved since their saved screen. It is serialised with the lifecycle (the sandbox's gate).
- **Looking never wakes**: `sessions` answers from the saved screens (`saved: true`, `savedAt`,
  `savedReason`) while the sandbox is paused, asleep or hibernated — in-process too; `session-screen` (read-only)
  gives one back. The CLI prints the TEXT; `--vt` writes the guest's bytes only when stdout is not a
  terminal.
- **The layout is the host's** (`terminal-layout.json` beside `doz.json`, `TerminalLayout`: one or
  two panes, ≤ 16 tabs, session names by the host's rule, mode interactive|watch). `terminal-layout`
  is a read; `terminal-layout-set` goes through the host when one runs (serialised with `rm`) and is
  otherwise answered IN-PROCESS (it is UI state, like doz.toml — writing it never starts a host); it
  refuses to create a directory. Reset clears it. The web route decodes the body STRICTLY
  (`WebTerminalLayout.decode`) and the host validates again.
- **The page** restores the stored layout once per page load (`restorePanes`) — not while the sandbox
  is under way (it waits for the next settled refresh) — and writes its panes back (debounced) only
  after that, so arriving never overwrites the stored layout with an empty page. Restored tabs load
  their engine the first time they are SHOWN (a hidden frame has no size, and an interactive attach at
  no size would resize the session). A sandbox that does not run shows its saved screens in the
  frame's `saved` mode: read-only and selectable, sending NOTHING (no keys, reports, focus reports or
  paste); a key is only announced (`{t:'key'}`) and the page starts the ordinary wake/resume action.
  Once it runs, each saved pane (and grid tile) goes live IN PLACE (`{t:'live', mode}`, then the
  attach's SNAPSHOT). A saved pane holds no socket, so it keeps no host alive (T3).
- **New is new (S4)**: New shell (shell-N, the next free name — saved names count as taken) and the
  Terminal… dialog (a new shell, or a new session running a command) never attach to a running
  session; a running one is reached through its pane or Home's Open (635). Split's watch/attach kinds stay: they name the left pane's session explicitly.

## Boot logs

- **Every boot is kept** — each Start (`cold boot`), wake (`wake`, also a wake on use) and restore after
  a crash — by the HOST (`BootRecorder` from `beginBoot` to `endBoot` around the library call in
  `HostCore`): the sandbox's own host events of that boot (exactly what the boot view draws; never a
  connection record or a console line), that boot's part of `bootlog.log` (from its size at the start
  of a wake; all of it for a cold boot, which starts the file afresh), and `BootLogInfo` (started, kind,
  duration, result, failure). `<sandbox>/boots/b-<epoch ms>/{boot.json,events.jsonl,console.log}`,
  0700/0600, written atomically (a temporary directory renamed), never into a removed sandbox; the
  newest `host.boot_logs_kept` (5) are kept. Kept across reset, gone with `rm`, never copied by
  duplicate/fork/templates. Recording never fails a boot. 651: a wake's boot log also holds its background steps
  (recorded until `.afterWakeDone`, written then; its time is the wake's), and a restore into a new process
  times its parts as `restore: …` steps (kernel, image store, kernel sha256, vmnet, container object, VZ
  configuration, VZ restore, VZ resume, the proxy listener) — the extra over an in-process wake.
- **One renderer**: `BootLogs.render` replays the events through `ProgressBoard` +
  `ProgressTerminal.format` — the boot view's finished lines (✓/✗ with times) — then the console made
  inert (every control character removed). The CLI (`doz console --steps`, plain off a terminal) and
  the web's Boot log (`GET …/boots`, `GET …/boots/N`, rendered on the server, drawn in the frame's saved
  mode — read-only, no socket, any phase) use it. `boot-log` is a read-only host op (in-process when no
  host runs; the host adds the boot under way as number 1).

## Session bridges

- **One place: the host's attach relay.** Every terminal (`doz attach`/`run`/`up`, every `doz ui` pane)
  reads a session through `HostServer.pump`, so the bridges live there: `SessionBridgeScanner` takes
  OSC 52 and OSC 6340 (`doz-open`) out of DATA frames (never a SNAPSHOT — a replayed screen must not
  re-copy; `reset()` on each), `HostCore.bridge` decides (nonisolated — pbcopy and `open` never run on
  the actor), and each viewer is told with `ClientWire.notice` (`ESC]777;doz;notice;KIND;TEXT BEL`,
  every control character stripped). Both clients take notices out BEFORE `findEnding`, and hold an
  unfinished one (`ClientWire.unfinishedNotice`) — a notice split by a read must never reach a screen.
- **Two viewers of one session see every sequence twice**: `BridgeState.once` acts once (the copy's
  hash within 2 s — serialised, so two pumps cannot both act) and both get the notice.
- **An OSC 52 READ is never answered and never forwarded** (the outer terminal would answer it with the
  Mac's clipboard); logged once per session. Everything a scanner does not own passes through byte for
  byte (`SessionBridgeTests` cuts at every offset).
- **The CLI's drawn line** (a notice; B4's menu) is DECSC → bottom row → reverse video → DECRC, removed
  by a REPAINT (`ClientWire.repaint`, `0xFF 'S'`): the host sends deckhold HELLO 0×0 on the live
  connection (`SessionConnection.repaint`) — a fresh snapshot, no resize, no deckhold change.
- **Per-sandbox settings** (`DozableSettings.perSandbox`): `SandboxConfig.settings[key]` wins over the
  file (`HostCore.sandboxValue`); `sandbox-settings` reads (in-process when no host) and sets;
  `doz config … --sandbox`, `doz create` flags, `doz_project.yaml` keys (`DozableProject.settingKeys`,
  synced by `doz up`). `sandbox.agent_sudo` keeps its own field. The recipe words `approvals` and `history`
  (`DozableSettings.recipeWords`) stand for the sandbox's recipe's own key (`recipeWordKey`); `history` resolves with
  `follow` passed down (`DozableSettings.history(agent:own:from:)`, recipes.md).
- **The browser bridge (B2)** is DeckStack's technique, re-done (never a DeckStack dependency): the
  guest shim (`GuestCommand.openShim`, `/usr/local/lib/doz/bin`, written by `prepareGuest` AND at each
  session open — a woken sandbox predates it) writes ONLY `ESC]6340;doz-open;URL BEL` to `/dev/tty`, else
  `$DOZ_TTY` (deckhold exports the session's pty: a `setsid` opener has no ctty), else stdout when it IS a
  terminal, else refuses (exit 1) — `2>/dev/null` BEFORE `>` on each rung. **Never a line a person sees**
 : text written behind an
  agent's TUI desynchronises its cursor-relative redraw (Claude Code draws blanks as cursor jumps — the
  shim's leftovers showed where spaces should be: "space doesn't work" in the web pane, which attaches at
  the session's size and so never makes the TUI redraw); the Dozable notice tells the person, stderr + the
  exit status tell the caller. Every viewer reads the host's stream through ONE `ClientWire.ViewerStream`
  (notices out, the end found, a notice's start held — `XdgOpenSilenceTests` cuts at every offset). `BrowserBridge.check` = http/https only, never
  the Mac's loopback; `callback(in:)` reads ONLY `redirect_uri` (http, `localhost`/`127.0.0.1` exactly,
  explicit port ≥ 1024). `LoopbackForward` binds the Mac's 127.0.0.1 (+ [::1]) BEFORE the URL opens,
  relays each connection through `Sandbox.openGuestStream([deckhold, connect, -p, PORT])` (no NIC
  needed), ends 3 s after the first answered callback or at 10 min; one per sandbox. Notices and the
  host log show `BrowserBridge.shown` (scheme, host, path) — never the query (a sign-in's state).
- **A login shell resets PATH** (/etc/profile on Alpine and Debian): the shim's dir comes back through
  `/etc/profile.d/doz-browser-bridge.sh` (written with the shim). A test in `bash --norc -i` would not
  have caught it — `test-cli-browser` checks `bash -lc`.
- **tmux (B3) runs INSIDE deckhold**, never instead of it: `GuestCommand.inTmux` = `tmux -L doz-NAME -f
  tmuxConfPath new-session -A -s NAME ARGV…` — a server PER SESSION (a shared server would give a later
  session the first one's environment: its placeholders, its `$DOZ_TTY`). `tmuxPrepare` writes the conf
  and answers `tmux=yes|no` in the one root exec the session open already makes; no tmux → run without
  it + `SessionOpened.notice`. The conf keeps the bridges alive (`set-clipboard on` + the clipboard
  feature: tmux passes OSC 52 out; the shim sends its marker to `$DOZ_TTY` when `$TMUX` is set, because
  tmux drops a sequence it does not know). The "already running" check compares the wrapped argv too.
  tmux is in `devBaselinePackages` and `labPackages` — a recipe change: W28's "older recipe" names it.
- **Dozable's tmux 3.8 runs the sessions** (658; the bases ship 3.3a–3.6a — `probes/658-*` in the workspace):
  `Guest/tmux/build.sh` builds it static (aarch64-linux-musl) with the pinned Zig from sha256-pinned tarballs
  (tmux 3.8, libevent 2.1.13, ncurses 6.6 — terminfo from /etc, /lib, /usr/share, /usr/lib), committed as
  `Resources/tmux` (`make tmux` / `make tmux-verify`; audit 6c checks PROVENANCE.md and the licence texts);
  `ToolsLayer.tmuxSHA256` pins the bytes (`TmuxBinary.verified` refuses others; `$DOZ_TMUX` overrides). The tools
  layer copies it to `GuestCommand.dozTmuxPath` (+ the `/usr/local/bin/tmux` link when free) and KEEPS it when off.
  **A tmux server answers only a client of its own version**: `tmuxPrepare(session:)` answers `tmux=doz`, or
  `tmux=sys:PATH` when Dozable's is missing/cannot run/no xterm-256color terminfo, or when a LIVE server of that
  session runs another version (`list-sessions -F '#{version}'` — a session started before the update keeps its
  tmux); `inTmux(binary:)` puts that path first; `inTmuxForms` is what "already running" accepts; `endSession`
  kills with Dozable's, then /usr/bin/tmux, /bin/tmux. The conf is unchanged and parses on both (3.8 and the
  distro's — `source-file -n` in the suite). **Theme**: tmux 3.8 sends `CSI ? 2031 h` + `CSI ? 996 n` at client start
  and asks OSC 10/11; an attached viewer's terminal answers (`CSI ? 997 ; 1|2 n`), deckhold does not (no colour-scheme
  callback), and tmux reports it to a pane's `CSI ? 996 n` — nothing to set (`theme` default: detect).
  **OSC 7501 does not pass**: tmux drops unknown OSC; Claude Code (2.1.310) and pi send 7501 plain (only images and
  clipboard are wrapped for tmux), so `allow-passthrough` would show nothing for them — left OFF (a wrapped report
  does reach deckhold with it on: measured). `make test-cli-tmux38` (Debian + Alpine, scratch store, seams).
- **The title and the Ctrl-] menu (B4)**: no reserved rows. The attach client pushes the
  terminal's title (CSI 22;0 t) the first time it sets one, re-renders `TerminalTitle` each minute and
  on every attach answer (a switch, a hold: the host's attach answer now carries `image`), and pops it
  (CSI 23;0 t) with W13's restore; `TitleFilter` keeps the session's OSC 0/1/2 out while it does. The
  menu: the FIRST detach-key press (any W16 encoding — `DetachKeyScanner` now returns what followed it
  in the read) opens it when stdin AND stdout are terminals; while it shows, `writeSession` drops the
  session's bytes (a notice waits in `pendingNotices`); closing it asks for a REPAINT. A second press
  within 0.5 s or at the menu detaches. n/p/s set `switchTarget` and shut the socket: the main loop
  reattaches THAT session in the same client. `MenuKey.decode` reads keys in plain, kitty CSI-u (a
  release is not a press) and modifyOtherKeys form. The web pane's tab renders the same template
  (`terminalTitle(t)` in `components/terminal.js`).
- **A host of another build is said**: `noteHostBuild` — once per command, on stderr before the
  answer, never with `-q`, never on stdout; `rawCall` (every host request but ping/host-stop) and
  `doz attach` call it. `hostBuildNote` uses the web UI's `WebVersion.compare` (a newer host: upgrade
  this doz). `image ls` STATUS is always a word (W32; a template is `up to date`).
- **Workspace folders**: a FOLDER — /workspace itself (relative path "") or any
  child, the same mapping and Mac-side `realpath` — opens with `open -a Finder` (never as an app); a
  package folder (`URLResourceValues.isPackage`, or a never-list extension) is refused even then.
  `doz-open --reveal` (`doz-reveal;PATH`, `BridgeEvent.revealFile`) is `open -R` — nothing opens, so a
  file's type is not checked and a package may be revealed; never outside, never with `--app`. Seam
  lines `open-folder PATH` / `reveal PATH`. The facts block has ONE `{{mac.open}}` line for every open
  bridge (only what is on; empty → the bullet is dropped by `AgentPrompt.render`); the skill keeps
  `{{browser.description}}` and `{{files.description}}`.
- **Workspace files ride the SAME shim and marker** — never a second guest→host channel. The shim
  (`openShim`, stamp `doz:open-url-shim:vN` — bump it on ANY change, so a wake's `guestFixes` re-installs
  it) takes a file as well as a URL and sends `ESC]6340;doz-file;APP;/workspace/… BEL` (made absolute and
  resolved in the GUEST, only so the agent hears refusals at once — the notice goes to the person). The
  HOST decides in `WorkspaceFiles` and trusts nothing the guest said: lexical normalisation under
  /workspace → the Mac folder from the sandbox's SPEC (`shares`, never a guest path) → `realpath` ON THE
  MAC, inside the shared folder's own realpath → a regular file (a folder, so any bundle, never) → the
  document allow-list / never-list (`GuestCommand.openFileDocumentTypes` / `openFileNeverTypes`, shared
  with the shim) → no executable bit → the content (`O_NOFOLLOW` descriptor, same dev/ino as the lstat,
  no `com.apple.ResourceFork`, no Mach-O/ELF/`#!` in the first bytes). A named app must be in
  `bridges.open_apps` and the LISTED spelling reaches `open -a`. `sandbox.open_files` per sandbox; its own
  rate limit (`BridgeState.fileOpens`). Notices are one terminal row (the CLI cuts at the width): keep
  every refusal short, the key fact first. The notice names the default app through LaunchServices,
  read-only (`MacDefaultApp` — the audit allows CoreServices there and in `UICommand.swift` only).
  `make test-cli-openfiles`.
- **Tests never touch the Mac**: `DOZ_TEST_PASTEBOARD=<file>` replaces pbcopy; `DOZ_TEST_OPEN_URL=<file>`
  replaces `/usr/bin/open` and plays the browser's last step (GET the callback on the Mac's port); a
  workspace file is recorded there as `open-file APP|default MACPATH`. 646: `DOZ_TEST_EDITORS=<ids>` stands in for
  LaunchServices' answer of which known editors are installed (`EditorApps`).
  A fake OAuth server must READ before it answers (busybox `nc -e`), as a real one does.

## What the agent is doing (OSC 7501)

- **deckhold is the consumer of the program-status protocol** (OSC 7501 —
  https://www.superlogical.com/rex/docs/build/program-status). Claude Code (≥ 2.1.295) and pi (≥ 1.1.0) report
  ONLY after the terminal answers `ESC]7501;?ST`; deckhold reads every byte its program writes (attached or not), so
  `ps_scan` in `pump_master` answers the query at once — always (a viewer's own terminal may answer too: a program
  takes the first), at most 16 answers a second (an answer echoed back as output must not loop) — and keeps the
  records by the spec (a report REPLACES its record; clear by id and below, or all; RIS clears; ≤ 256, LRU; a
  malformed pair skipped, a report over a limit / bad base64 / control characters discarded whole). The bytes are
  NOT changed: the emulator and every viewer get them as written (`SessionBridgeScanner` does not own 7501 —
  `SessionStatusTests` cuts it at every offset). OSC 133 `A` deliberately does NOT end working/blocked: Claude
  Code writes it at its own turn start and reports only on change. Codex does not report (nothing shown).
  Grok Build ≥ 1.0.52 reports too (`app=grok-build`; its `ui.notifications.program_status = "auto"` default, nothing set):
  it sends the query only where it already asks the terminal for its version — deckhold's `TERM=xterm-256color` with no
  `TERM_PROGRAM` is such a terminal — and never inside tmux (it would need `program_status = "on"` and tmux's
  `allow-passthrough`, neither set). Inside tmux (3.8 too) NO agent's status is seen: tmux drops OSC 7501 and the
  agents send it plain (see tmux B3). Its `working` carries a msg ("Waiting for response…", "Service unavailable (502) |
  Retrying (n/15)"), its `done` "Turn complete in 4.0s."; `blocked` is `state=blocked:app=grok-build:kind=permission:msg=<the command>`
  (seen in its ask mode, `DOZ_GROK_PERMISSIONS=ask` + `--permission-mode default`, on a network command — a write to
  /tmp ran without asking). `probes/617-*/stageF/grok-status-run.sh` and `grok-blocked-run.sh` are the VM proofs.
- **What deckhold exposes is the ROOT record**: in `deckhold ls`'s INFO (`status=<canonical report body>\tstatus_age=S`,
  BEFORE the command — an older parser takes an unknown field for the command, which comes last) and as STATUS
  ('T') frames to a client that sent WATCH ('W'). Frame types are only ever appended (the header comment). 648: the
  WATCH answer announces GRID (`grid=1`), and the watcher is also the transport of `session-grids` (see "GRID only to
  a holder that ANNOUNCED it"). An
  older holder (a session started before an update keeps its binary) drops a WATCH client: the host's watcher then
  ends with no STATUS frame (`SessionConnection.sawStatus`) and that session is not asked again until the next run.
- **The host holds it in memory** (`HostCore+Status`): one watcher per session of a RUNNING sandbox
  (`Sandbox.watchStatus` — `deckhold pipe` + WATCH: not a viewer, no size), opened on open-session, on an attach,
  and for every live session when the sandbox comes to run (ONE `deckhold ls` per transition — never on a poll);
  the library detaches it with the viewers on sleep/stop. `ls` reads memory only (`sessionStatuses`,
  `agentStatus` = `SessionStatus.mostUrgent`: blocked > error > working > done > idle, `agentWorking` — the
  signal an idle sleep must respect). working/blocked end with the program; done/error survive it until the
  session is opened again or the sandbox stops. Each change is ONE `session-status` HostEvent (deduplicated:
  `sameReport`), sent only to an `events` stream that set `HostRequest.sessionStatus` (an older client cannot
  decode the kind). **The program's `msg`/`title` are untrusted guest text: never in host.log** (`logLine` is
  metadata only), capped in `WebAgentStatus`, textContent only on the page.
- **The page** (`components/agent-status.js`): chips on tabs, tiles and Home's card and rows (`data-agent-for`,
  painted in place after every overview), the sidebar's dot, and a page notice per transition to done / blocked /
  error (dropped when no longer true; 635.B2: never for the session being watched — its tab shown in a focused window —
  dropped once it is, and a done one goes by itself after 10 s). The UI's monitor pokes its poll on a `session-status` event; it is not an
  Activity line. `probes/612-*/browser-status.mjs` checks it in a real Chrome (scratch store and profile).
