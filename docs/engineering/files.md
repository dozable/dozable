# Files: the watcher and the explorer

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableHost/WorkspaceFileList.swift`, `HostCore+Files.swift`, `FileWatch.swift`; `Sources/DozableCLI/FileCommands.swift` (`FilesCommand`); `Sources/DozableWeb/WebFiles.swift`; `Sources/doz-vmtest/FilesSuite.swift` | 643: the file watcher — a folder's listing (the Mac for a shared workspace, the guest for an isolated one; the rules applied), the host op `files-list`, the FSEvents watch (coalescer, target, hub — CoreServices, audit), `doz files`, the files routes + their SSE stream; `FilesTests`, `WebFilesTests`, `make test-cli-files` |
| `Sources/DozableHost/WorkspaceFileChange.swift`; `HostCore+Files.swift`; `Sources/DozableCLI/FileCommands.swift` (`doz files` group); `Sources/DozableWeb/WebFiles.swift` (`WebFileTree`, `WebFileOpen`); `WebSource/app/views/sandbox-files.js` | 644: the file explorer panel — the changes on the Mac (confined, descriptor-relative, the rules) and in an isolated guest, the kept open folders (`FileTreeState`), `files-open`; the Files tab; `FileChangeTests` |
| `Sources/DozableHost/EditorApps.swift` (+ `MacDefaultApp.appPath`); `FilesOpen --app`, `FilesEditors`; `WebEditor`, `GET /api/v1/editors`; `WebSource/app/components/open-with.js` | 646: Open Workspace — a shared workspace (or a folder or file in it) in an editor: the known editors found by bundle id, `bridges.open_apps`, the host op `editors`; the terminal strip's Open folder menu and the Files tab's Open in <editor>; `EditorAppsTests` |

## The file watcher — `files-list`, `doz files`, the files routes

- **Listing follows the bytes.** `files-list` (read-only host op: in-process when no host runs) reads a SHARED workspace ON
  THE MAC in any phase — never a guest call — with the open-files bridge's path discipline (`WorkspaceFiles`): the asked
  path normalised lexically under /workspace (`..` above it refused), mapped onto the folder from the sandbox's RECORD,
  `realpath`, and it must stay inside the share's realpath; entries are `lstat`ed (a link's target is display only, never
  followed). An ISOLATED sandbox is listed by one utility exec as the image's user (`GuestFolderListing`: `stat -c`, names
  passed as `./NAME`) ONLY while it runs — asleep/off is `invalid-phase`, never a wake or a start.
- **The workspace rules apply as the guest's view applies them** (a rule file present and `workspace.view` on): hidden
  absent, locked listed `locked` with no size or time, read-only marked; a hidden folder is "no such folder", a locked one
  refused; decided on the RESOLVED path (`WorkspaceRules.Evaluator`, the same as `doz ignore check`).
- **Names are untrusted text**: `FileListPaths.inert` (control and bidi-control characters → U+FFFD, ≤ 255 characters) on
  the host, before any client; the CLI's `Console.printable` too.
- **The watch is NOT a host op** (keep it so): it runs in the process that asks — `doz ui`'s server, `doz files --watch`
  — with FSEvents on the share (CoreServices, `FileWatch.swift` only — the audit). A host stream would be a held
  connection, which keeps an idle host alive (T3), and with no host a watch would have to start one. One FSEventStream
  per sandbox per process (`FileWatchHub`), stopped with its last watcher; `FileWatchCoalescer` turns file-level events
  into ONE batch per watcher per 250 ms naming the watched folders whose listing changed — never a name (a hidden one
  never travels; inside a locked folder nothing counts) — or `resync` (dropped events, the root moved, a rule file
  changed, > 64 folders). ≤ 64 folders per watcher. An isolated sandbox is not watched (refresh on demand) until the
  owner rules on a guest watcher (a `deckhold` subcommand or a new pinned-Zig guest program).
- **Web**: `GET …/files?path=P` (`WebFileList`, a projection) and `GET …/files/watch?path=P…` (its OWN SSE hub `filesHub`
  — never the page's live-update stream's — `files-ready` then `files` events, the same bounded queue / heartbeats /
  ends: sign-out, rotate, revoke, shutdown, restart). The query is decoded strictly (`WebFilesQuery`: `path` only, `%XX`
  only, no `+`, UTF-8, no control character; else 404). Both `read` in `WebExposure`.

## The file explorer panel — the Files tab, `doz files mkdir|new|mv|rename|rm|open`

644 (owner: "expanded / collapsed state is persisted; CRUD operations"; placement: a Files tab in the sandbox page's
inspector). `Sources/DozableHost/WorkspaceFileChange.swift`, `HostCore+Files.swift`, `WebSource/app/views/sandbox-files.js`.

- **Four changes, one host op each, one `WebAction` each, a CLI twin each**: `files-mkdir` (never `-p`), `files-new` (an
  empty file), `files-move` (a rename is a move in its folder; `fileTarget`), `files-rm` (`recursive` for a folder with
  contents; destructive: `confirm` = the guest path, the page's tick box). Nothing is EVER replaced; `/workspace` itself is
  never changed (`FileItemPath`: one name, never the root); a folder never goes into itself. Never a generic write route.
- **A shared workspace is changed ON THE MAC, never through a guest, never starting a host**: these ops (with
  `files-open` and `files-tree-set`) are `HostOp.isAnsweredWithoutHost` — through the host when one runs, else
  in-process (`terminal-layout-set`'s rule), and `HostWebData.perform` sends them through `query`, never an autostart. The
  path discipline is the listing's: the PARENT resolved by `MacFolderListing.resolve` (lexical, from the record, realpath
  inside the share's realpath, a link out refused), the item ONE name in it, and every change descriptor-relative on the
  parent opened `O_NOFOLLOW` (`mkdirat`, `openat(O_EXCL|O_NOFOLLOW)`, `renameatx_np(RENAME_EXCL)`, `unlinkat`; a recursive
  delete walks with `openat(O_NOFOLLOW)` — a link inside is removed, never followed; ≤ 100 000 entries). Keep it that way:
  never a path string re-resolved after the check.
- **The rules, as the guest's view decides** (a rule file present and `workspace.view` on; on the RESOLVED inside path):
  a hidden item is "no such file", a locked or read-only one is refused, nothing is made in a read-only folder, a NEW name
  (mkdir, new, a move's destination) must come out visible, a folder moved or deleted must hold nothing the rules protect
  (at its old and its new place). The rule files are read-only by the rules, so they are never moved or deleted here.
- **An isolated sandbox**: one utility exec as the image's user (`GuestFileChange`: `cd` + `pwd -P` must be /workspace or
  below, an existence check first, `mkdir`/`set -C`/`mv`/`rm` on `./NAME`), RUNNING only — asleep/off `invalid-phase`
  ("this never wakes or starts it"); with no host, in-process says the same.
- **`files-open`** (shared only; `POST …/files/open` — `WebExposure` **mac-screen**: never for a doz serve browser;
  `doz files open [--reveal]`): `WorkspaceFiles.decide` exactly as the agent's `xdg-open` (`sandbox.open_files`, document
  types, the content sniff, a folder in the Finder, reveal) plus the rules (hidden/locked refused), `WorkspaceFiles.open`
  (the `DOZ_TEST_OPEN_URL` seam). Nothing reads a file's content into the browser.
- **Open in an editor** (646, owner: "open the workspace in my editor"; `files-open`'s `app`, `doz files open NAME [PATH]
  --app APP`, the page's `{path, app}`): the PERSON's action, never the agent's bridge (`WorkspaceFiles.decide` from a
  guest marker still refuses `--app` on a folder). `app` never reaches `open -a` as typed: `EditorApps.resolve` takes a
  KNOWN editor (`EditorApps.known`: id · name · bundle ids) that is INSTALLED — its `.app` path from LaunchServices by
  bundle id (`MacDefaultApp.appPath`, read-only; CoreServices stays confined to that file), opened by that path — else a
  `bridges.open_apps` name (the listed spelling). It opens a folder (not a package) or a file that is not executable, not
  a program or `#!` by its first bytes, and not a never-type — except the source-text ones (`WorkspaceFiles.editorSourceTypes`:
  sh, py, js, swift…, refused for a default app, which could run them); the document allow-list does not apply. The rules
  first (hidden = no such file, locked = refused), `sandbox.open_files`, isolation, as above. `editors` (read-only, no
  sandbox) answers `[{id, name}]`: the known ones installed, then `bridges.open_apps`; `GET /api/v1/editors` is
  **mac-screen** like `files/open`. Seams: `DOZ_TEST_EDITORS=vscode,zed` (the installed known ones, at a path that does not
  exist) and `DOZ_TEST_OPEN_URL` (`open-file <editor name> PATH`). The page (`components/open-with.js`): the editor list
  asked once per page; the last used first (`doz.openWith`, this browser); the terminal strip's **Open folder**
  (`folder-open`, beside Open in Terminal: Show in the Finder + Open in <editor>, `code-xml`; disabled with why for an
  isolated sandbox; not drawn when `isRemote()`) and the Files tab's ⋯ on a folder or a file.
- **The open folders are the host's** (`FileTreeState`, `<sandbox>/file-tree.json`, 0600, atomic, ≤ 63 + /workspace = the
  watch's 64, each a clean relative path once): `files-tree` (read-only) / `files-tree-set` (in-process when no host runs;
  never creates a directory), `GET|POST …/files/tree` (strict `{expanded}`, `WebFileTree.decode`). Kept across shutdown and
  reset (the page drops a folder that is gone); gone with `rm`.
- **The page** (`views/sandbox-files.js`): ONE persistent element per sandbox re-inserted into the rebuilt inspector (so
  what is open, selected and focused stays); a live refresh never re-lists — the first show, a watch batch (only the
  folders named; `resync` = every open one), Refresh, its own change (the folders it touched), an isolated sandbox coming
  to run. The watch (643's stream, ONE per page) is open only while the tab is the shown tab of the visible page with the
  details open, for a shared workspace, naming /workspace and every open folder (re-opened, debounced, when that set
  changes; retried after 5 s). An isolated sandbox that does not run is asked NOTHING (the page knows the phase). Rows:
  `.frow` `role=treeitem`, indent `--depth` set through CSSOM (the CSP refuses a style attribute); keys ↑↓→← Home End
  Enter F2 Delete; a drag onto a folder is a move; a name the host altered (`altered`) is not changed here. An open row
  menu holds the page's re-render (its close runs the held one).
- **Tests**: `FileChangeTests` (the item rule, every change on a scratch folder, links, the rules, the guest script run
  under /bin/sh, the kept state, in-process ops, open through the seam), `WebFilesTests` (routes, strict bodies, a real
  listener), `WebActionTests.testTheFileActions`, `ServeExposureTests`; `make test-cli-files` (2b: changes while off with no
  host, refusals, open through the seam, asleep stays asleep, isolated inside and refused asleep); the workspace probe
  `probes/644-*/files-panel.mjs` (screenshots 1440/390, light/dark).
