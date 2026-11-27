# Troubleshooting and FAQ

`doz doctor` first; then find your error below by its words. The failures people meet most, by name: **this Mac's
Claude login expired**, **connection refused** on a chat port, **an Ask nobody answered**, **a command timed out**
(exit 124), and **a refused host** that looks like a DNS error. Each has its row in [The common five](#the-common-five).

## Start here

```sh
doz doctor
```

`doz doctor` checks everything Dozable depends on — macOS and Apple silicon, the virtualization
permission, the Linux kernel, the NAT helper, disk space, the daemon, your Claude login and your images
— and says what to do about anything that fails. The dashboard's **Doctor** page shows the same.

Then, depending on what's wrong:

| to see | run |
|---|---|
| What the daemon is doing, live | `doz events` (or `doz events NAME`), or the dashboard's **Activity** |
| How a start or wake went | `doz console NAME --list`, then `doz console NAME --steps` — or **⋯** › **Boot log** on the sandbox's page |
| What the agent was refused | `doz net NAME` (the suggestions), `doz net log NAME --denied` |
| Everything about a sandbox | `doz inspect NAME` |
| What the agent is told | `doz inspect NAME --prompt` |
| The daemon's log | `<store>/daemon.log` (the store is `~/Library/Application Support/doz` by default) |
| Where the disk went | `doz resources` |

Add `-v` to any command to see every step it takes.

## The common five

| what you see | why | what to do |
|---|---|---|
| "this Mac's Claude login expired at 04:59" (or a 401 from the model) | The Mac's Claude Code login lasts about 8 hours, and only the Mac's Claude Code renews it. | Run `claude` on the Mac once (any prompt), or `doz account keepalive always`. A daemon started over SSH cannot renew it: start it from the Mac's desktop, or use a setup-token account (`doz account add NAME --setup-token`). See [Agents and accounts](09-agents-and-accounts.md#how-the-mac-login-stays-fresh). |
| "connection refused" from `dozchat`, or no answer on 8790 | Chat is off, its server is restarting, or the agent is talking to another port — each store has its own (a second store, a moved port). | `doz chat status` (on, ready, its ports). An agent Dozable starts is given the right address (`CHAT_URL`); one you started yourself needs `CHAT_URL=http://host.dozable.internal:PORT` (in a sandbox or fenced session) or `http://127.0.0.1:PORT` (on this Mac), with the page port `doz chat status` shows. On another machine, see [Tokens and identity](43-tokens-and-identity.md#agents-on-other-machines-and-a-machine-without-a-token). |
| An agent waits and nothing happens | It asked a question nobody answered: an Ask waits for a decision, and expires to decline (in 24 hours unless it says sooner). | `doz chat asks` lists the open ones; answer in the room or with `doz chat decide ROOM N OPTION`. `doz workspace state W` lists what waits for you. |
| exit 124, "timed out" | `doz exec` stops a command after 120 s by default (a `wait` or `dozchat journal wait` after its `--timeout`); what the command left running is reaped, never left `<defunct>`. | `--timeout SECONDS` for a long command, or `doz run NAME -d` to run it in the background ([Terminals and sessions](07-terminals-and-sessions.md)). |
| `403` with "refused by Dozable's network policy", or `ENOTFOUND` inside a sandbox | The host is not allowed. A program that uses the proxy (curl, npm, pip, git) is told so; one that looks names up itself (Node's own `https`) sees a DNS error. | `doz net NAME` names the host and the allow command; in a workspace, `doz workspace show W --network`. See [the network](10-permissions-and-network.md). |

## Common problems

### Installing and upgrading

| symptom | what to do |
|---|---|
| `doz: command not found` | `brew list doz`, then open a new terminal window. |
| `Error: … unexpected arguments: 'host', …` | The old command name `host` is now `daemon` (`doz daemon start\|stop\|restart\|status\|upgrade-check`); the old command no longer exists. A 0.40 store and settings are carried over automatically, once. See [Upgrading](02-install-upgrade-uninstall.md). |
| "cannot boot a VM", or about the entitlement | `doz doctor`; `brew reinstall doz`. A self-built copy must be signed (`make install-cli`). |
| "this daemon's program … is gone — an upgrade removed it" | `doz daemon stop`, then retry. |
| "this daemon's program was updated underneath it" | `doz daemon stop`, then retry. |
| "note: the doz daemon is X (this doz is Y)" | A daemon of the previous version still runs and answered: `doz daemon stop` (sandboxes hibernate, and wake on the new version). |
| The menu bar app says "doz is not installed" | It looks for doz at `/opt/homebrew/bin/doz`, `/usr/local/bin/doz` and `~/.local/bin/doz`. Install doz with Homebrew (or `make install-cli`, which puts it in `~/.local/bin`). See [The menu bar app](35-the-menu-bar-app.md). |
| The menu bar app says doz is older than it needs | `doz upgrade -y`. Until then the menu still shows the daemon's state and offers Start, Stop, Restart and Open Dashboard. |
| The menu bar app says "Daemon started from ssh — it cannot read your Keychain" | The daemon was started over ssh, so it cannot read your Claude login. Choose **Restart Daemon** in the menu (or `doz daemon restart` in Terminal on the Mac): the new one starts in your desktop session. |
| The menu bar app says "Daemon runs an older build" | doz was upgraded while the daemon ran. **Restart Daemon** switches it (running sandboxes hibernate and wake on the new version). |
| `doz app install` says the copy "does not verify" | The app beside doz was changed after it was signed. Reinstall doz (`brew reinstall doz`, or a fresh tarball), then `doz app install` again. |

### Starting and waking

| symptom | what to do |
|---|---|
| The first start takes minutes | It's preparing the image, once. `doz onboard --status` shows it. |
| A start fails | `doz console NAME --steps`: the failing step is marked ✕, with why. |
| A wake fails | `doz daemon stop`, then wake again (a failed wake keeps its snapshot). If it says it was put to sleep by another version in a machine this one can't rebuild, wake it with that version, or shut it down. |
| Last resort for a stuck sandbox | `doz shutdown NAME` then `doz start NAME`: programs end, the disks are kept. `claude --continue` resumes Claude Code's last conversation. |
| A sandbox shows as died | The daemon crashed while it ran; `doz start NAME` checks its disk and boots it. |
| "not possible in this phase" | `doz ls` shows its state; e.g. `resume` only works on a paused sandbox. |

### Agents and accounts

| symptom | what to do |
|---|---|
| The agent says it has no key, or gets 401 | `doz account ls`, `doz key ls NAME`. A typed key is gone after the daemon stopped. |
| "this Mac's Claude login expired" | Run `claude` on your Mac once, or `doz account keepalive always`. |
| `doz account ls`: "keep-alive … skipped: Claude Code (pid N, …) holds its own copy" | A Claude Code that is not fenced runs on this Mac; renewing would cancel its copy of the login. It renews when that Claude Code is next used. |
| `doz account ls`: "keep-alive … FAILED (exit 1: …)" | Run `claude` on the Mac (any prompt) to see why it cannot renew: a sign-in may be needed. |
| pi can't be created | pi needs an API key account: `doz account add NAME --api-key`. |
| "the agent prompt does not render" | `doz inspect NAME --prompt` names the unknown `{{variable}}`; fix it or `doz config set agent.prompt false`. |
| `sudo apt-get install` fails with a network error | `doz net NAME`: system packages need `install:system` (on in Standard). |

### Workspaces and chat

| symptom | what to do |
|---|---|
| `doz workspace start` lists gaps | Each comes with the command that fixes it: chat on, a room (`doz workspace edit W --make-room`), a folder gone, a bot not ready. |
| `doz workspace run` is refused, `run-open` | A unit of work is still open — `doz workspace reopen` opens one too. `doz workspace finish W` first. |
| `dozchat journal add` exits 4, naming `journal.write` | An agent writes the journal only once you grant it: `doz grant AGENT reviewer --in W`. |
| An entry is refused, `no-open-run` | The journal takes entries only while a unit of work is open: `doz workspace run W`. |
| An adopted agent hears nothing in the room | A session already running when it was adopted has no chat token until it restarts (`adopt` printed the command that hands it over now); and nothing tells it to listen: say in its prompt to run `dozchat receive`. |
| A worker never starts: "needs chat" | `doz chat on`, then `doz workspace start W` again. |

### Network

| symptom | what to do |
|---|---|
| A package install or download fails | `doz net NAME` shows the refusal and the permission that allows it. |
| A site works in your browser but not in the sandbox | `doz net log NAME --denied`: it often needs a second host. |
| Everything is refused | The sandbox may be `locked`: `doz net NAME`, then `doz net allow NAME standard`. |

### Terminals and the dashboard

| symptom | what to do |
|---|---|
| Ctrl-] doesn't detach | Once opens the menu on the bottom row; press it again (or `d`). |
| "Sign in with a new link" | Paste a link from `doz ui link --print-url` into the page, or open one with `doz ui link`. |
| A browser terminal says "Disconnected" | It was silent a long time or could not reattach: **Reconnect**. After `doz ui` restarts it reattaches by itself. |
| The installed dashboard app says "Dozable isn't running on this Mac" | Run `doz ui`; the window comes back by itself. |
| The dashboard is paused under an overlay | `doz ui` stopped: start it again and the page reconnects. |
| Open in Terminal does nothing | Make a terminal app the handler for `.command` files (Finder › Get Info › Open with › Change All…). |
| A copy didn't reach the clipboard | Look at the notice (off, too big, too many); `doz config show --sandbox NAME`. |
| A sign-in page didn't open | Is a terminal attached? Is `sandbox.browser_bridge` on? See [Signing in from a sandbox](11-signing-in-from-a-sandbox.md#troubleshooting). |
| A file of the sandbox's folder didn't open on the Mac | Read the notice (and the program's own message): outside `/workspace`, not a document type, executable, an app not in `bridges.open_apps`, an isolated sandbox, or `sandbox.open_files` off. See [Opening your folder's files](07-terminals-and-sessions.md#opening-your-folders-files-on-your-mac). |

### Images and disk space

| symptom | what to do |
|---|---|
| An image says "older recipe" or "update available" | Rebuild when it suits you (`doz image bake NAME`, or **Rebuild**); `doz reset` the sandboxes you want on it. |
| The disk is filling up | `doz resources`, then `doz resources clean --dry-run`. |
| "Dockerfile changed — rebuild available" | `doz image bake df-…`, then `doz reset NAME`. |

### Sessions after a wake

| symptom | what to do |
|---|---|
| Codex: `turn/start failed: invalid cwd: No such file or directory` after a wake; a shell's `ls .` says `No such file or directory` | The program's folder was cut off by a wake from hibernation — a sandbox still on the plain share (`folder.view` off, or started before 0.30.0). Restart the session: `doz sessions restart NAME SESSION` (the conversation continues), or **⋯ › Restart session** on its tab. From its next start the sandbox uses [the folder view](21-the-workspace-view.md) and this does not happen again. |
| The agent gets "Permission denied" writing `/workspace`, or git says "detected dubious ownership" | The sandbox runs a folder view from before Dozable 0.33.1, under which the sandbox's user could not write the shared folder. `doz shutdown NAME` and `doz start NAME` give it the current view (a wake keeps the old one). Another user than the sandbox's own cannot write through the view — see [Who can write](21-the-workspace-view.md#who-can-write). |
| `doz doctor` warns "folder view" | The live view of `/workspace` could not start, so the folder is shared directly. `doz console NAME --steps` shows why; `doz shutdown NAME` and `doz start NAME` try again. |
| A program is stuck | `doz sessions restart NAME SESSION`, or `doz sessions end NAME SESSION`. |

## FAQ

**Is a sandbox a container?**
No. Each is a Linux virtual machine with its own kernel, run by Apple's Virtualization framework.

**Does a sandbox slow my Mac down when I'm not using it?**
A running sandbox holds its memory; a paused or sleeping one holds it but uses no CPU; a hibernated
one holds nothing. `doz hibernate NAME` when you're done for the day.

**Will I lose work when a sandbox sleeps or hibernates?**
No: programs, sessions and screens come back exactly where they were.

**Where are my files?**
Your project folder stays on your Mac (the sandbox sees it at `/workspace`). Everything else is on the
sandbox's disks in the store.

**Can the agent see my other files, my keychain or my clipboard?**
No. It sees only the folder you shared, never a credential, and never your clipboard (it can only
*write* to it, with a notice, if you let it).

**Can I use Dozable offline?**
Mostly. Sandboxes start, sleep and wake offline; preparing an image needs the internet the first time,
and `latest` agent versions need it to be resolved (set an exact version to avoid that). The agent
itself needs its AI model, of course.

**Can I move a sandbox to another Mac?**
Not yet with a command. A snapshot (sleep, hibernate) is encrypted with a key specific to this Mac.

**Why does `doz` say "the next command starts a new daemon"?**
The daemon is a background process that runs your sandboxes; it keeps running (`daemon.always_on`) and replaces
itself after an update. You never need to start it: any command that needs it does — after `doz daemon stop`, after
it exited idle (with `daemon.always_on` off, after `daemon.idle_timeout_minutes`, 5 by default), or when it was started
over ssh and exited after 5 idle minutes.

**Why does `doz` say "the running daemon is …, this doz is …"?**
The daemon running now is of a version that does not speak this doz's language (0.51 renamed what a sandbox works on
to its *folder*, and the two would misread each other). Run `doz daemon stop`: your sandboxes hibernate, and the next
command starts a daemon of this version, which wakes them.

**`doz` says "Unknown option '--workspace'" (or `--workdir`).**
Renamed in 0.51: `--workspace` is `--folder`, `--workspace-view` is `--folder-view`; `--workdir` is `--folder` on
`doz run @mac` and `--cwd` in a sandbox (`doz run NAME`, `doz exec NAME`). The error says the new name. A settings line
`[workspace] ignore_mode` or `view` is not read any more — say `[folder]` (every command warns until you do), and
`workspace_view:` in `doz_project.yaml` is `folder_view:`.

**How do I start completely fresh?**
`doz uninstall`, then `brew uninstall doz`, `brew trust --tap dozable/tap`, `brew install dozable/tap/doz` and
`doz onboard`. Your project folders
and keychain are untouched.

**The account `mac` is "unreadable", though `claude` works on this Mac?**
The doz daemon reads your Claude login in the session it was started from. A daemon started over ssh (or from
another session with no login) cannot read the login keychain — `doz account ls`, `doz ls` and `doz doctor` say
so, naming the daemon. Run `doz daemon restart` from your logged-in session (a terminal on the Mac itself). A
command over ssh that has to start the daemon warns first; `doz image bake` over ssh stops the daemon it started
once nothing runs. With the login item (`doz daemon login-item on`) a command over ssh starts the daemon in your
desktop session instead ("doz: started the daemon in your desktop session (login item)"), so it can read the login.

**`doz daemon restart` over ssh says "not restarted"?**
The running daemon was started from your desktop and can read your login Keychain; one started over ssh could not.
Run it from Terminal on the Mac — or add the login item once (`doz daemon login-item on`, from the Mac), after which a
restart over ssh starts the new daemon in your desktop session. `doz daemon stop` over ssh always works.

**macOS said "Background Items Added: doz"?**
That is the login item `doz daemon login-item on` (or "Start Dozable when you log in?" in `doz onboard`) added: one
plist in `~/Library/LaunchAgents` that starts the doz daemon when you log in. `doz daemon login-item` shows it;
`doz daemon login-item off` removes it. Switched off in System Settings › General › Login Items, it stays off —
`doz doctor` says so.

**"Dozable" in Login Items?**
That is the menu bar app's **Start at Login** (System Settings › General › Login Items & Extensions; macOS said "Login
Item Added" when you clicked it). It starts the daemon when you log in, and the menu with it; doz's own login item is
then removed, so there is only one. Turn it off from the menu (uncheck Start at Login) or with `doz app uninstall`.
Switched off in System Settings, the menu says "Start at Login — needs approval: Open System Settings…" — click it to
go there and switch Dozable back on. `doz daemon login-item` says who starts the daemon at login.

**The menu says "Start at Login — needs doz 0.50.8" (or "doz … is older than this app needs")?**
The menu bar app came with a newer doz than the one it finds (it uses `/opt/homebrew/bin/doz`, `/usr/local/bin/doz` or
`~/.local/bin/doz`, in that order). Upgrade that doz (`doz upgrade -y`, or `brew upgrade`); the menu notices within a
minute. Start, Stop, Restart and the dashboard work meanwhile.

**The menu says "Start at Login — open the copy in Applications"?**
That copy of the app runs from outside Applications (a download, or Homebrew's own folder). Run `doz app install --open`
and use the copy in `/Applications`.

**Everything is slow — a wake takes a minute?**
Run `doz doctor`. When `doz` was started at macOS background priority (by `taskpolicy -b`, or by a tool or agent that
runs in the background), it and everything it starts run many times slower; doctor's `priority` line says so and how
to move it out. A daemon started that way leaves the background priority by itself (`daemon priority` in doctor).
When the daemon, or a session it holds on this Mac, runs at utility QoS, doctor says so too (`daemon priority`,
`session priority`): macOS then runs it mostly on the efficiency cores, so an agent's builds and tests are slower than
the same work in a terminal. Stop the daemon (`doz daemon stop`), let a command from a normal terminal start it, then
start the session again.

**Exit codes?**
`0` ok · `1` failed · `2` not found · `3` not possible now · `4` already exists · `5` not
confirmed · `6` daemon unavailable · `7` not implemented yet · `8` limited · `9` not permitted · `64` usage ·
`65` an invalid document or value · `75` partly done · `124` timed out. `doz help exit-codes` lists them with
the error codes `--json` carries. `exec`, `run` and `attach`
exit with the program's own code (`125` when `doz` itself failed; `exec`'s `124` when its `--timeout`
passed — `--json` adds `"timedOut": true`).
