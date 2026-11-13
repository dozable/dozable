# Sessions on this Mac

Every other page of this manual is about sandboxes: a program in its own small Linux machine, with a network that
reaches only what you allow and none of your keys. This page is about the one exception. **`@mac` is this Mac
itself.** A session there is held exactly like a sandbox's — you can detach from it, attach again from another
terminal, type into it from a script, read its screen, see what its agent is doing, end it and restart it — but the
program runs on your Mac, as you.

Use it for the work that has to happen on the Mac: building a Mac or iOS app with Xcode, driving the Simulator, an
agent working on a project that only builds here. Use a sandbox for everything else.

A new session on this Mac is **fenced** by default: macOS's own sandbox (Seatbelt) holds the program and everything
it starts to its project folder, its own temporary files and caches, and Dozable's proxy for the network. Your
Keychain, your secrets and your other folders are closed to it. `--unfenced` opts one session out — then nothing is
around it at all.

## The idea, in plain words

A fenced session may change its project, and nothing else of yours that something unfenced would later run or load.
Its temporary files, its tool caches, its agent's settings folder and its git settings are its own, kept in a folder
Dozable makes for that session — so nothing it writes there can be picked up later by your own terminal, your own
Claude Code or your Xcode. The only thing it shares with you is the project folder itself: that is its work, and
you review it as you would any change.

Everything else follows from that rule:

- **Reads:** the system, your tools (what your `PATH` finds, Homebrew, toolchains, Xcode) and your `~/.ssh/config`
  and public keys. Not your home's other files: not `~/.ssh`'s keys, `~/.aws`, `~/.config`, `~/Library`, your shell
  history, your other projects.
- **Writes:** the project folder, and folders you name with `--write`.
- **Network:** only through Dozable's proxy, by the session's permissions — the same switches a sandbox has
  ([What the agent can do](10-permissions-and-network.md)). Every connection is logged. Never this Mac's own
  addresses.
- **Keychain:** closed. `--keychain` opens it (signing as you needs it — and then it could read your saved logins too).
- **Logins:** Claude's and GitHub's reach the program as placeholders; the proxy puts the real one in on the way out,
  so the program never holds your token.

## Five ways to start one

The dashboard's **This Mac › New session on this Mac…** offers these five; each card shows exactly what it opens and the
command (Dozable never starts a session for you from the page — you run the command in a terminal on the Mac).

| case | what it is | the command |
|---|---|---|
| **Plain agent** | an agent on one folder: its own temp and caches, your Keychain closed, the network through the proxy | `doz run @mac -d --session agent --workdir ~/src/app -- claude` |
| **Web / Node development** | the same, and the ports of your dev server — it may listen on them, and your browser and tests reach them | `doz run @mac -d --local-port 3000 --workdir ~/src/site -- claude` |
| **Swift / Xcode development** | builds into the session's own DerivedData; optionally **Run in the Simulator** (`--simulator`) and **Sign with my Apple identity** (`--keychain`) | `doz run @mac -d --xcode --workdir ~/src/MyApp -- claude` |
| **Signing & notarisation** | no fence: Apple's signing and notary tools need your Keychain and their own networking | `doz run @mac -d --unfenced --workdir ~/src/MyApp -- zsh -l` |
| **Unfenced** | no isolation at all — your files, Keychain and network, as if you typed it yourself | `doz run @mac --unfenced --session shell` |

More you can do with the command line (cards may come later): `--write DIR` for a second repository, `--ssh-agent` for
git over ssh with your keys, `--permissions locked` for a research session that reaches only its AI model.

## Starting one

```bash
cd ~/src/my-app
doz run @mac -d --session agent -- claude          # fenced, in the folder you are in
doz run @mac -d --session build --xcode -- zsh -lc 'xcodebuild -scheme MyApp -derivedDataPath "$DOZ_DERIVED" -scmProvider system build'
doz run @mac --unfenced --session shell            # no fence; no command: your login shell, attached
doz run @mac --dry-run -- claude                   # what it would be able to do — nothing is started
```

- `--session` names it (at most 32 characters); without it, the program's name.
- `--workdir` is the project folder. Fenced, the default is **the folder you are in**, and your home itself, `/`, a
  folder that holds your home, or Dozable's own folders are refused (a fenced session must have a project folder).
  Unfenced, the default is your home.
- `-d` starts it and returns; without `-d`, `doz run` attaches to it, as for a sandbox.
- There is no `--user`: a session on the Mac runs as you.
- The program starts without a shell in front of it; say `-- zsh -lc '…'` for one.

`doz run @mac` prints one line saying what it opened — fenced: `[doz] fenced: reads and writes ~/src/my-app; its own
temp, caches and Claude Code settings; network through Dozable's proxy (standard permissions); your Keychain, secrets
and other folders closed — doz run @mac --unfenced for none of this`; unfenced, that it has no isolation.

**Which one is used:** `--fenced` or `--unfenced` on the command, else the environment variable `DOZ_MAC_FENCE`
(`on` or `off`), else the setting `mac.fence` (`on` by default). A flag that only a fenced session has (`--keychain`,
`--xcode`, `--local-port`, …) means fenced; with `--unfenced` it is refused.

| flag (fenced) | what it opens | setting for the default |
|---|---|---|
| `--keychain` | your Keychain (signing; and so your saved logins) | `mac.keychain` (`off`) |
| `--read DIR`, `--write DIR` | one more folder, read-only or read-write (never your home, `~/.ssh`, `~/.config`, `~/Library` or the store) | `mac.fence_read` (read-only, relative to your home) |
| `--permissions` | what it may reach: `standard`, `locked`, `open`, a permission, `-PERMISSION`, `site:HOST` | `mac.permissions` (`standard`) |
| `--local-port N` | it may listen on, and connect to, `localhost:N` — a dev server, a sign-in callback | — |
| `--agent-config private\|shared` | the agent's settings folder (below) | `mac.agent_config` (`private`) |
| `--history keep\|agent-default` | what happens to its conversations (below) | `agent.history` |
| `--account NAME\|mac\|none` | the Claude login the proxy swaps in | `mac.account` (`mac`) |
| `--github off\|read\|push` | GitHub as you, through the proxy (read refuses pushes) | — |
| `--ssh-agent` | your SSH agent, for listing keys and signing only | — |
| `--xcode`, `--simulator` | Xcode's build services; the Simulator too | — |
| `--open-url`, `--open-files`, `--clipboard` | the bridges (below) | `mac.open_url`, `mac.open_files`, `mac.clipboard` |

## Its files

Each fenced session has a folder of its own, `~/Library/Application Support/Dozable/fence/…/SESSION/`, which only it
(and Dozable) uses:

- **`tmp`** — its `TMPDIR`, emptied at every start.
- **`cache`** — every tool cache Dozable knows of (npm, pip, uv, Go, SwiftPM, Python, `XDG_CACHE_HOME`,
  `XDG_CONFIG_HOME`). Kept between starts, so the second build is warm; the first one starts cold. Emptied when a start
  opens MORE than the last one did (`--keychain`, `--simulator`, `shared`, another folder or port, wider permissions),
  so nothing written under narrower rules is used under wider ones.
- **`derived`** — Xcode's DerivedData (`$DOZ_DERIVED`).
- **`agent`** — the agent's own settings folder, when it is private.
- **`etc`** — what Dozable writes for it and it may only read: its git settings (your name, email and ignore file,
  taken from yours; nothing else of your git config), the certificate the proxy uses, its shell's start-up file.
- **`ssh/known_hosts`** — a copy of yours, made again at every start; host keys it learns stay here.

Your own temporary folder, `/tmp`, `~/Library/Caches` and `~/Library/Developer` are not writable from inside — the
exceptions are the few folders Apple's build tools insist on making in your temporary folder whatever they are told
(`swift build` and `xcodebuild` fail without them).

**Git, guarded.** Inside its folder a fenced program can commit, branch, fetch and push, but it cannot write a git
hook, rename a `.git` folder away, create one at the top, or point a repository's settings anywhere that would run
something the next time *you* use git there. Git settings it may add are the everyday ones (branches, remotes, `push
-u`, LFS, submodules); anything else — `core.hooksPath`, `core.fsmonitor`, a pager, an `insteadOf`, an unknown key — and
**the session is stopped at once**, the change taken out and kept aside:

```bash
doz sessions @mac                       # says: agent is STOPPED: a git config change …
doz sessions @mac --quarantine agent    # what was taken out
doz sessions resume @mac agent          # continue without it
```

The dashboard shows **Stopped: git config** on its tile, with **Review…** and **Resume**. A resume is refused while
the key is still there. Because every `.git` folder is protected, `rm -rf` of a clone fails inside a fenced session —
remove it from your own terminal.

## Its agent's settings folder: private or shared

For Claude Code (the agent whose recipe declares where it keeps its settings), there are two ways:

- **Private** (the default): the session has its **own** Claude settings folder. Your `CLAUDE.md`, skills, agents,
  commands and output styles are there as **read-only** links (one that points somewhere closed is not followed); its
  `settings.json` is a cleaned copy of yours — only a short list of safe keys, so no hooks, status line, MCP servers or
  plugins come along; it is made again at every start, so nothing the agent changes there survives. Your own
  `~/.claude` is closed to it. Your conversations of that folder are copied in at its first start, so `claude -c`
  finds them.
- **Shared** (`--agent-config shared`): it uses your **own** `~/.claude`. Convenient — everything you have set up
  is there — but **less isolated**: what it writes into your settings (a hook, a status line script, a plugin) runs the
  next time you use Claude Code yourself, outside the fence. Said when it starts, and in every view of it.

`mac.agent_config` sets the default for every agent; `recipes.anthropic.claude-code.mac_config` for Claude Code alone
(`follow` follows `mac.agent_config`).

**The Claude login** is swapped in by the proxy: `--account mac` (this Mac's own Claude Code login, the default),
`--account NAME` (one of `doz account ls`) or `--account none`. The program holds a placeholder, never your token, and
signs in with no prompt. Claude Code gets a short note in its prompt saying where it runs (`mac.agent_prompt`).

## Its conversations (transcripts and history)

A private settings folder is the session's, so its conversations would go when the session does. They don't: when the
session ends, is restarted, removed, or found gone, Dozable **copies its conversations back** into your own
`~/.claude/projects/<folder>/`, where a later `claude --resume` (or `-c`) in that folder finds them. Only the
conversation files are copied — never its memory, to-dos, settings or anything else — and only ones that are what they
claim to be (one per conversation, for that folder); anything else is named and left behind. A copy of yours is replaced
only by a longer version of the same conversation; otherwise both are kept.

What else happens follows the conversation-history setting (`agent.history`, per agent
`recipes.anthropic.claude-code.history`, or `--history` for one session):

- **`keep`** (the default): copied back, and **also kept in Dozable's own archive**:

  ```bash
  doz sessions @mac --transcripts agent                    # what was kept, when
  doz sessions @mac --transcripts agent --export ~/saved   # copies
  ```

  The dashboard's **Conversations** tab lists and downloads them.
- **`agent-default`**: copied back, where Claude Code's own rule decides how long they stay; nothing archived.

A shared session writes its conversations straight into your own folder, and Dozable never changes your settings
there. A conversation written in a fenced session and continued outside it is still text the fenced agent wrote:
the end message says so.

## The network

The session's proxy decides by host name, with the permissions of a sandbox. This Mac's default for a fenced session
(`mac.permissions` = `standard`) is: its AI model, its own updates, GitHub, error reports, and the Node, Python, Go,
Rust and Swift package registries. `locked` is its model only; `open` is any site, still logged.

```bash
doz net @mac --session agent                    # its permissions and what it was refused lately
doz net allow @mac --session agent install:ruby site:api.example.com
doz net deny @mac --session agent github
doz net log @mac --session agent --denied --follow   # its connections
doz net log @mac --session agent --fence        # the fence's own refusals: files, programs, services
```

Changes apply to its next connection. Name lookups (DNS) are closed inside the fence — the proxy looks names up;
`localhost` still works. A program that ignores the proxy settings gets no network at all, rather than a direct one.
`--local-port N` is the one way to listen: the program may listen on and connect to `localhost:N` only, so your
browser and tests reach its dev server there. `doz net log … --fence` shows the fence's refusals so far; it does not
follow new ones (`--follow` works for connections).

Under `locked`, macOS's certificate service is closed too, so tools that check certificates through it (Go programs,
`gh`) cannot reach anything; under `standard` it is open (it fetches revocation lists on the program's behalf).

**GitHub as you** (`--github read` or `--github push`): git and `gh` are signed in as you, through the proxy — your
token stays on the Mac; `read` refuses pushes. Without it, a push over https has no credential (git says how).
**Git over ssh** works through the proxy too; your keys only with `--ssh-agent` (list and sign — never added, removed
or read), and host keys it learns stay in the session.

## Tools inside the fence

| tool | fenced | how |
|---|---|---|
| git over https, LFS, worktrees, submodules | works | through the proxy |
| git over ssh, `ssh` | works | through the proxy; your keys only with `--ssh-agent` |
| GitHub (git, `gh`) | `--github read` or `push` | the proxy puts your token in |
| signed commits | ssh signing with `--ssh-agent`; gpg fails | your `gpg.*` settings are not carried in |
| Node, npm, pnpm, bun | work | caches in the session |
| curl, Python, pip, uv | work | |
| Go | works; `go install` lands in the session's caches | a host whose traffic the proxy reads (GitHub with `--github`) fails for Go programs |
| Swift, SwiftPM | `swift build --disable-sandbox` | SwiftPM's own sandbox cannot run inside another; binary packages need their host allowed |
| Xcode | `--xcode`, and `xcodebuild … -derivedDataPath "$DOZ_DERIVED"` | without it Xcode's DerivedData is closed; signing needs `--keychain` |
| Simulator | `--simulator` | a guard rail, not a boundary (below) |
| codesign, notarytool, tools that use Apple's own networking | fail | run them unfenced (the Signing & notarisation case) |
| Java | fails | no proxy for Java yet |
| Docker, Podman, VMs, `open`, `osascript`, `sudo` | refused | |
| headless Chrome, Playwright | `--no-sandbox`, browsers in the session | Chrome's own sandbox cannot run inside another |

The list of macOS services Claude Code and Xcode may use inside the fence is still being settled from real sessions;
a later version may open or close a few. `doz net log @mac --session NAME --fence` shows what was refused.

## Bridges

A fenced program cannot open things on your Mac itself (that would reach outside the fence), so Dozable does it for it,
as for a sandbox — each time announced in `doz attach` and the dashboard:

- **Open a URL** (`open`, `xdg-open`, `$BROWSER`): an http or https page opens in your browser (never `file:` or other
  schemes, never this Mac's own addresses; at most a few at a time). A sign-in whose callback is the program's
  `localhost:N` works when the session has `--local-port N`; otherwise it is refused before anything opens, and the
  message names the flag.
- **Open files**: a document from its folder opens in your app (never a program, a link out of the folder, or an app
  bundle).
- **Clipboard**: it can put text on your clipboard (OSC 52), never read it; each copy is announced with its first
  characters, so a command planted for you to paste is visible.

`--open-url off`, `--open-files off` and `--clipboard off` turn one off for a session; while it runs,
`doz sessions bridges @mac agent --open-url off` (or the switches on its dashboard panel) changes it at once. An
unfenced session's program opens things itself, as before; its copies reach your clipboard as from any session.

## What it can do, at a glance

```bash
doz sessions @mac --capabilities agent    # one line per capability: its state, what it opens, when it can change
doz run @mac --dry-run --xcode -- claude  # the same, for a session before it starts
```

The rows: the fence (fenced, fenced (Xcode), guard rail (Simulator), no isolation), the Keychain, the network, the
agent's settings folder, history, the Claude login, GitHub as you, the SSH agent, the three bridges, and the folders it
can write and read. Each says whether it can change **live** (the network's permissions, the bridges) or **at the next
start**. `--json` has them as `capabilities`, for unfenced sessions too. The dashboard shows the same rows on a
session's **What it can do** tab, and up to four as chips on its tile.

## What the fence is not

Said plainly, so you can decide:

- **Not a virtual machine.** It is macOS's own sandbox around one program and what it starts, running as you. A
  sandbox (`doz new`) is a separate machine; prefer it when the work does not need the Mac.
- **Your project files are its work.** It can change anything in its folder — a `Makefile`, `package.json`'s scripts,
  a test — and what you run there later, unfenced, runs that. Review its changes as you would anyone's.
- **Names and sizes of files are visible everywhere** (not their contents).
- **Other programs' command lines are readable.** Any program you run can read the command line (not the
  environment) of your other programs, fenced or not — never put a password or token on a command line.
- **The Simulator is a guard rail, not a boundary.** With `--simulator`, the Simulator and the apps it launches run
  outside the fence.
- **`--keychain` and `shared` open real doors**: your saved logins, and your own Claude Code settings.
- **A git setting is taken out within a second** — between its write and the stop, an unfenced git run in that folder
  could still read it once.
- **macOS's certificate service** checks certificates for it under `standard`.

## Looking, typing, attaching

```bash
doz sessions @mac                            # the sessions: state (fenced, no isolation …), what the agent is doing, folder, command
doz sessions @mac --json                     # each with its workdir, argv, when it was opened, its fence and capabilities
doz attach @mac build                        # Ctrl-] opens the menu (d detach · n next · p prev · s sessions)
doz sessions screen @mac build               # its screen as text, now
doz sessions send @mac agent --text 'run the tests' --enter
doz sessions wait @mac agent --until idle,done,blocked,error --timeout 90   # has it stopped working?
```

These are the same commands as for a sandbox's sessions ([Terminals and sessions](07-terminals-and-sessions.md)).
Looking (`doz sessions @mac`, `screen`) never starts a host. `doz ls` ends with one line for this Mac: how many run,
fenced or not.

## What `@mac` is, and is not

- **It is a place, not a sandbox.** Its name starts with `@`, so it can never be a sandbox's name (those are `a-z`,
  `0-9` and `-`). Only the session commands take it — `doz run`, `doz attach`, `doz sessions` — and `doz net` for a
  fenced session (`--session`). Every other command (`doz exec`, `doz start`, `doz sleep`, `doz key`, …) refuses it.
- **Its environment is built new.** The program gets `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG`, `LC_*`,
  `TERM=xterm-256color`, `COLORTERM=truecolor` and `PATH` — nothing else of the environment `doz` was started from.
  `PATH` is your login shell's, read once. A fenced session adds its own: the proxy, its caches, its certificate, its
  agent's settings folder (and no `SSH_AUTH_SOCK` unless `--ssh-agent`); an unfenced one gets your `SSH_AUTH_SOCK`. Add
  what you need with `-e NAME=VALUE`. The markers that tell a program it runs inside Claude Code (`CLAUDECODE`,
  `CLAUDE_CODE_*`) are never passed on, and `-e` refuses them; a fenced session also refuses `-e` of a login
  (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `GH_TOKEN`, …) — the proxy brings those.

## In the dashboard

`doz ui` has a **This Mac** page (in the sidebar, under All sessions — tagged with how many run with **no isolation**,
when any do; `#/mac`), and All sessions ends with a This Mac section. Each session is a tile with its picture, what its
agent is doing, its folder and its chips — **Fenced**, **Fenced (Xcode)**, **Guard rail (Simulator)**, **Keychain
open**, **Shared config**, **GitHub: push**, or **No isolation** — and marks for news: network waiting for a host,
refusals seen, **Stopped: git config**. A session whose own command line bypasses its permissions says **permissions
bypassed**.

- **Watch** (or a click on the picture) opens it below, **watching**: nothing you type reaches it. Its tabs: the
  screen, **What it can do** (the capabilities; the bridges' switches change live), **Network** (its permissions,
  read-only, with the `doz net` commands; its connections and the fence's refusals), **Conversations**.
- The pane's two-state toggle, **Watching** | **Controlling**, says which it is and switches: Controlling attaches for
  real (the tile's **Control** does the same). It is offered only to a browser that may type into these sessions, and
  only while the session runs. **Restart…** and **End…** ask first.
- **New session on this Mac…** (this Mac's own browser) is the five-case guide above (its folder starts as the newest
  session's, never a temporary folder): it shows the command, **Copy**,
  and **Open in Terminal** for the plainly fenced cases (Plain agent, Web / Node, Swift / Xcode without the Simulator
  or the Keychain, private settings). Anything with less of a fence is copy-only, so no single click starts it.

**Your other browsers** (the dashboard's LAN option, [The dashboard on your other devices](25-doz-serve.md)) do not get
these sessions unless you say so — a browser on your network typing into one is typing on your Mac. The setting
`serve.mac_sessions` decides, on the Mac (never from a browser):

| `serve.mac_sessions` | what another computer's browser may do |
|---|---|
| `off` (the default) | nothing — the page and its entry are not there |
| `watch` | list them and watch them (read-only); no typing, no Restart, End, Resume or bridge switches |
| `interactive` | everything this Mac's own browser does with them, except New session |

```bash
doz config set serve.mac_sessions watch        # applies at once
```

This Mac's own browser (`doz ui` on the Mac) always has them. A sandbox never reaches any of it.

## Bypass only when asked

Dozable never adds a flag that skips an agent's permission questions for a session on the Mac. If the command you give
asks for it itself — `claude --dangerously-skip-permissions`, `claude --permission-mode bypassPermissions`,
`codex --dangerously-bypass-approvals-and-sandbox` — that is your choice and it is allowed, and the session is marked
**permissions bypassed**: once on `doz run`'s output, and in `doz sessions @mac` (and `"bypassed": true` in `--json`)
for as long as it is listed. Fenced, the fence still holds; unfenced, such an agent can harm your Mac.

## Sleep, logout, restart

- **Sleep and closing the lid: kept.** Each session is held by its own small process (`deckhold-mac`), which simply
  pauses with the Mac.
- **The host: not needed to keep them.** The holders are not the host's children. `doz host stop` says how many
  sessions on this Mac keep running; the next host finds them again (same program, same screen). A fenced session's
  network waits for a host: its connections are served when one runs again.
- **Logout and restart: gone.** Logging out or restarting the Mac ends every program, sessions on the Mac included.
  Afterwards `doz sessions @mac` lists them as **gone**; `doz sessions screen @mac NAME` shows the screen saved last,
  and `doz sessions restart @mac NAME` starts the same program again in the same folder. Claude Code continues the
  folder's newest conversation (`--continue`) unless you pass `--fresh`. The variables you gave with `-e` are not
  kept (they might be secrets): give them again with a new `doz run`.
- **A restart keeps the session's mode.** A fenced session restarts fenced, with the same grants and its folder made
  again; one opened unfenced — every session opened before fenced became the default included — restarts unfenced.
- `doz sessions end @mac NAME` ends a program (hang-up, then terminate, then kill; fenced, every process of its fence,
  even ones that detached). Ending one that has already ended or is gone forgets it.

## Upgrading from a version without the fence

- Sessions you opened before keep running, and keep their mode when restarted: unfenced.
- A new `doz run @mac` without a flag is now fenced. A script that needs the old behaviour — calling `doz` from inside
  the session, using your Keychain, reaching any host, writing outside its folder, running from your home — passes
  `--unfenced` (or set `doz config set mac.fence off`). A fenced session's refusal says what was refused and names
  `--unfenced`.
- An older `doz` does not know `--unfenced`: check `doz run --help` before relying on it in a script.

## The Keychain, and a host started over ssh

An unfenced program (or a fenced one with `--keychain`) uses your login Keychain only when the doz host runs inside your
logged-in session. A host started from an ssh connection runs where the Keychain is locked: `doz doctor` says so, and
the fix is `doz host restart` from a terminal on the Mac itself. macOS may also ask about a session's program on behalf
of `doz` ("doz wants to access your Documents folder") — the dialog names `doz` because it started the holder.

## Uninstalling

`doz nuke` ends every session on the Mac. `doz uninstall` asks whether to end them (`--yes` ends them); left running,
no `doz` can reach them again once the store is gone.
