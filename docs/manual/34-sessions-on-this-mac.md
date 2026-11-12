# Sessions on this Mac

Every other page of this manual is about sandboxes: a program in its own small Linux machine, with a network that
reaches only what you allow and none of your keys. This page is about the one exception. **`@mac` is this Mac
itself.** A session there is held exactly like a sandbox's — you can detach from it, attach again from another
terminal, type into it from a script, read its screen, see what its agent is doing, end it and restart it — but the
program runs on your Mac, as you, with **no isolation at all**.

Use it for the work that has to happen on the Mac: building and signing a Mac app with Xcode, driving the iOS
Simulator, a tool that needs your Keychain. Use a sandbox for everything else.

## What `@mac` is, and is not

- **It is a place, not a sandbox.** Its name starts with `@`, so it can never be a sandbox's name (those are
  `a-z`, `0-9` and `-`). Only the session commands take it: `doz run`, `doz attach` and `doz sessions`. Every other
  command (`doz exec`, `doz start`, `doz sleep`, `doz net`, `doz key`, …) refuses it with one message — there is
  nothing to start, sleep, wake or network. For a one-off command on your Mac, use your own shell.
- **Nothing is around the program.** No virtual machine, no proxy, no key placeholders, no workspace rules. It can
  read and change every file your user can, use your Keychain, reach any host on the network, and run anything.
  `doz run @mac` says so every time, `doz sessions @mac` says so at the top, and `doz ls` says so on its last line.
- **Its environment is built new.** The program gets `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `LANG`, `LC_*`,
  `SSH_AUTH_SOCK`, `TERM=xterm-256color`, `COLORTERM=truecolor` and `PATH` — nothing else of the environment `doz`
  was started from. `PATH` is your login shell's, read once (so Homebrew, `uv` and `claude` are found); if the
  login shell does not answer in time, the system's list plus `/opt/homebrew/bin` and `~/.local/bin`. Add what you
  need with `-e NAME=VALUE` (`-e PATH=…` and `-e DEVELOPER_DIR=…` work). The markers that tell a program it runs
  inside Claude Code (`CLAUDECODE`, `CLAUDE_CODE_*`) are never passed on, and `-e` refuses them: a session opened by
  an agent must not believe it is that agent.

## Starting one

```bash
doz run @mac -d --session build --workdir ~/src/my-app -- xcodebuild -scheme MyApp build
doz run @mac --session shell                 # no command: your login shell, attached
doz run @mac -d --session agent --workdir ~/src/my-app -e DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer -- claude
```

- `--session` names it (at most 32 characters); without it, the program's name.
- `--workdir` is a folder on this Mac (default: your home folder).
- `-d` starts it and returns; without `-d`, `doz run` attaches to it, as for a sandbox.
- There is no `--user`: a session on the Mac runs as you.

The program starts without a shell in front of it; say `-- zsh -lc '…'` for one.

## Looking, typing, attaching

```bash
doz sessions @mac                            # the sessions: state, what the agent is doing, folder, command
doz sessions @mac --json                     # each with its workdir, argv and when it was opened
doz attach @mac build                        # Ctrl-] opens the menu (d detach · n next · p prev · s sessions)
doz sessions screen @mac build               # its screen as text, now
doz sessions send @mac agent --text 'run the tests' --enter
doz sessions wait @mac agent --until idle,done,blocked,error --timeout 90   # has it stopped working?
```

These are the same commands as for a sandbox's sessions ([Terminals and sessions](07-terminals-and-sessions.md)).
Looking (`doz sessions @mac`, `screen`) never starts a host. A copy (OSC 52) reaches your clipboard as from any
session; the open-a-URL and open-a-file bridges are off — the program is on your Mac already and opens things itself.

## Bypass only when asked

Dozable never adds a flag that skips an agent's permission questions for a session on the Mac, and gives it no
environment prompt. If the command you give asks for it itself — `claude --dangerously-skip-permissions`,
`claude --permission-mode bypassPermissions`, `codex --dangerously-bypass-approvals-and-sandbox` — that is your
choice and it is allowed, and the session is marked **permissions bypassed — nothing around it**: once on
`doz run`'s output, and in `doz sessions @mac` (and `"bypassed": true` in `--json`) for as long as it is listed.
Think twice: in a sandbox such an agent can only harm the sandbox; here it can harm your Mac.

## Sleep, logout, restart

- **Sleep and closing the lid: kept.** Each session is held by its own small process (`deckhold-mac`), which simply
  pauses with the Mac.
- **The host: not needed.** The holders are not the host's children. `doz host stop` says how many sessions on this
  Mac keep running; a host killed or upgraded leaves them running; the next host finds them again (same program,
  same screen).
- **Logout and restart: gone.** Logging out or restarting the Mac ends every program, sessions on the Mac included.
  Afterwards `doz sessions @mac` lists them as **gone**; `doz sessions screen @mac NAME` shows the screen saved last
  (screens are saved every few minutes, and when the host stops), and
  `doz sessions restart @mac NAME` starts the same program again in the same folder. Claude Code continues the
  folder's newest conversation (`--continue`) unless you pass `--fresh`. The variables you gave with `-e` are not
  kept (they might be secrets): give them again with a new `doz run`.
- `doz sessions end @mac NAME` ends a program (hang-up, then terminate, then kill). Ending one that has already ended
  or is gone forgets it.

## The Keychain, and a host started over ssh

A program in a session on the Mac uses your login Keychain only when the doz host runs inside your logged-in
session. A host started from an ssh connection runs where the Keychain is locked: `doz doctor` says so, and the fix
is `doz host restart` from a terminal on the Mac itself. macOS may also ask about a session's program on behalf of
`doz` ("doz wants to access your Documents folder") — the dialog names `doz` because it started the holder.

## Uninstalling

`doz nuke` ends every session on the Mac. `doz uninstall` asks whether to end them (`--yes` ends them); left running,
no `doz` can reach them again once the store is gone.
