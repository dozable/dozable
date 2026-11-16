# Installing, upgrading and uninstalling

`doz` is one command-line program. It comes with everything it needs inside it: the small Linux
programs each sandbox uses, the Linux kernel sandboxes boot (so the first start downloads no kernel), the web
dashboard, and the permission macOS requires to run virtual machines. You install it with Homebrew.

## Concepts

- **The `doz` program** is what you install. It is signed with Apple's virtualization entitlement;
  without that, macOS refuses to boot virtual machines. A copy you build yourself without signing can
  run every command except the ones that boot a VM, and `doz doctor` says so.
- **The store** is where your sandboxes, images and restore points live:
  `~/Library/Application Support/doz` unless you choose another (see
  [Settings reference](15-settings-reference.md), `store.path`). Upgrading `doz` never touches it
  (0.37 is the one exception: it starts with a new store — see [Upgrading to 0.37](#upgrading-to-037-a-fresh-start)).
- **The settings** live in `~/.config/doz/doz.toml`, beside your agent prompt template
  (`agent-prompt.md`). Upgrading never touches them either.
- **The daemon** is a background `doz` process that runs your sandboxes. A running daemon keeps using the
  version of `doz` it started as, which is why upgrading has one extra step (below).

## Install

You need a Mac with Apple silicon and macOS 26 or later.

```sh
brew trust --tap dozable/tap   # once per Mac: Homebrew loads a third-party tap's formulas only once trusted
brew install dozable/tap/doz
doz --version
```

Recent Homebrew loads formulas from a third-party tap only after you trust it — `brew trust` is needed
once per Mac (without it `brew install` refuses the formula). Homebrew then adds Dozable's tap and installs
a prebuilt, signed and notarised `doz` in seconds — no compiler is needed. It ends with a hint: run `doz onboard` ([Setting up](03-setting-up.md)).

The tap used to be called `dozer-sandbox/tap`. If you installed from it, nothing changes: it still gets every
update, and `doz upgrade` uses it.

### Release channels

There is one formula per release channel; they install the same `doz` command, so you have one at a time:

| formula | channel | what you get |
|---|---|---|
| `dozable/tap/doz` | stable | releases |
| `dozable/tap/doz-beta` | beta | beta builds first, and every release |
| `dozable/tap/doz-canary` | canary | every build, first |

`doz upgrade --channel beta` switches: it asks, then Homebrew uninstalls one formula and installs the other.
Your store, sandboxes and settings are not Homebrew's and stay. doz never installs an older build — switching
to a channel whose newest build is older than yours waits until that channel catches up.

### Without Homebrew

Each release also has a tarball on the project's GitHub releases page: `doz-VERSION-macos-arm64.tar.gz` (and
its `.sha256`). Unpack it anywhere and put its `bin` on your `PATH`; keep the folder as it is (`bin/doz` is a
link into `libexec/doz`, where doz finds its parts). `doz upgrade -y` updates such an install itself: it downloads
the new tarball, checks it against the signed feed and Apple's signature, and swaps it in, keeping the
previous version as `libexec/doz.previous`.

The releases page also lists a `doz-VERSION-macos-arm64-helper.tar.gz`. That one is **not for you** unless you build a
Mac app that carries `doz` inside it: it has no dashboard and never updates itself. See
[Bundling doz in an app](33-bundling-doz-in-an-app.md). Each tarball also has a `.dSYM.zip` beside it — its symbols,
for reading crash reports; you don't need it to run doz.

## Upgrade

doz tells you when a new release is out — one line after a command on your terminal, and a banner on the
dashboard:

> doz 0.31.1 is available — upgrade: doz upgrade -y (notes: https://updates.dozable.com/v1/notes/0.31.1.html)

```sh
doz upgrade -y            # or doz upgrade: it shows the version and the notes, and asks first
doz daemon restart
```

`doz upgrade` refreshes Dozable's tap first, then runs `brew upgrade` for your channel's formula. It always asks the
feed itself (past any cached copy), so a release is there the minute it is published. Its first name, `doz update`,
still works. Homebrew's own output stays off the screen: no update of your other taps first, and what brew prints
goes to `brew.log` in doz's settings folder (`~/.config/doz/brew.log`) — shown when brew fails, or as it
runs with `doz upgrade --verbose`. When a daemon of the previous version is running, `doz upgrade` (without `-y`)
then asks whether to restart it now. Homebrew refreshes
its taps only now and then, so a plain `brew upgrade doz` can say there is nothing new for up to a day; with brew
directly, run `brew update` first.

- **How it knows.** At most once a day (and when `doz ui` starts), doz reads one small file,
  `https://updates.dozable.com/v1/feed.json`, signed with Dozable's own key; anything that doesn't verify
  is ignored. Nothing about you or your sandboxes is sent — only the request, with doz's version and channel
  in its user agent. Offline, it says nothing. Never with `--json` or `-q`, or when not on a terminal.
- **The setting `updates.mode`**: `notify` (the default), `auto` — doz also installs the update itself (through
  Homebrew for a Homebrew install), but only while no sandbox is running and no session is attached, and then says
  `Updated to 0.31.1 — restart to apply: doz daemon restart` — or `off` (never look). `doz upgrade --check` looks
  now, whatever the mode.
- Homebrew installs the new version beside the old one, then removes the old one.
- **A running daemon keeps its old version.** After an upgrade, Homebrew runs `doz daemon upgrade-check`,
  which says when a daemon of the previous version is still running. You can run it yourself at any time;
  it never starts or stops anything.
- **`doz daemon restart`** hibernates every running sandbox and starts a daemon of the new version (`doz daemon
  stop` does the same and leaves the next command to start it). Each sandbox wakes on the new daemon when you
  use it — with its programs and sessions where they were:

```sh
doz wake my-app        # or doz up, doz attach, or just use the dashboard
```

Until you do, every command that talks to the old daemon says so, once, on stderr (never in its output,
and not with `-q`):

```
note: the doz daemon is 0.12.0-rc.9 (this doz is 0.12.0-rc.10) — `doz daemon stop` switches to 0.12.0-rc.10; sandboxes hibernate and wake
```

(If the daemon is the *newer* one — you ran an older `doz` — the note says to upgrade this `doz`.)

If you skip `doz daemon stop`, nothing breaks right away: your sandboxes keep running. But the old
daemon can no longer boot anything once Homebrew has removed its files, so a start, a wake or a new
sandbox is refused with a message that tells you to run `doz daemon stop`. Once nothing runs and
nobody is attached, the old daemon replaces itself with one of the new version — no command needed (with
`daemon.always_on` off it just exits, and the next command starts the new one). A daemon that only holds
sessions on this Mac hands them over to a daemon of the new version the same way, the sessions running on.

### The daemon now stays running

From 0.50.4 the daemon no longer exits when nothing runs: `daemon.always_on` is on by default, and
`daemon.idle_timeout_minutes` now defaults to `0` (never). A `doz.toml` that already sets an idle timeout keeps
it, but it applies only with `daemon.always_on` off — `doz config show` says so. To have the daemon exit when idle
again:

```sh
doz config set daemon.always_on off
doz config set daemon.idle_timeout_minutes 5     # needed only if you never set one: its default is 0 (never)
```

A daemon started over ssh (where the login Keychain is locked) is never kept running: it still exits after 5
minutes with nothing running, so the next command from the Mac itself starts one that can read your Claude login.
`doz daemon status` says which it is.

### The background process is now called the daemon

The background process that runs your sandboxes is called **the daemon**, and its commands are `doz daemon start|stop|restart|status|upgrade-check`. The old command name `host` no longer exists (there is no alias: doz answers it with `unexpected arguments: 'host', …`), and `DOZ_HOST_IDLE` is replaced by `DOZ_DAEMON_IDLE`. A 0.40 store and its settings are carried over automatically, once: the first daemon takes over the old lock and log, the `host.*` settings are read and written back as `daemon.*` the next time `doz.toml` is saved, and an older daemon that is still running keeps serving until it exits by itself when idle (or until `doz daemon stop` switches).

### Upgrading to 0.37: a fresh start

0.37 is the first release with Dozable's own names on disk, and it **starts fresh**: nothing from an earlier
install is read — not your sandboxes, images, restore points, accounts, settings, prompt template or dashboard
links. There is no migration. Before you upgrade, with the version you have:

```sh
doz get my-app /workspace/notes.md ~/Desktop/   # copy out anything a sandbox holds that you want to keep
doz ui stop
doz daemon stop
```

Then upgrade and run `doz onboard` again: it makes the new store, settings and images (every image is built
afresh). New sandboxes' folders go to `~/doz-workspaces`; your project folders, wherever they are, are never
touched. When you no longer need the old install, remove its folders:

```sh
rm -rf ~/Library/Application\ Support/dozer-sandbox   # the old store: sandboxes, images, restore points, accounts list
rm -rf ~/.config/dozer-sandbox                        # the old settings and agent prompt template
rm -rf ~/Library/Caches/dozer-sandbox                 # the old download cache
```

The keys an earlier version saved stay in your login keychain (items named `doz-…`) until you delete them in
Keychain Access. Images an earlier version built with Apple's `container` are named `dozer/…` there:
`container image ls` lists them and `container image delete NAME` removes one.

### Your images after an upgrade

A new version of Dozable may prepare its images differently (it may add a tool, for example). Your
existing images are **never rebuilt without you**: Dozable says an image is out of date — in
`doz image ls`, `doz doctor`, when you create a sandbox, and on the dashboard's Images page — and
you rebuild it when it suits you. See [Images and bases](08-images-and-bases.md#out-of-date-images).

### A sandbox that slept through an upgrade

A sandbox asleep or hibernated when you upgraded wakes on the new version with everything where it
was. Each snapshot remembers the exact virtual machine it was taken in, and the wake rebuilds that
machine, including the Linux kernel it slept under. If a new version ever can't rebuild the same
machine, the wake is refused rather than risk the snapshot, and says so.

## In the dashboard

The dashboard watches the daemon. If a daemon of another version takes over, a banner says so; if the
daemon is **older** than the dashboard, the banner offers **Restart daemon**: it asks first, hibernates
the running sandboxes and starts the newer daemon (they wake when you use them). If `doz ui` itself is
the older one, the banner asks you to restart `doz ui`. See [The dashboard](06-the-dashboard.md).

## Uninstall

```sh
doz uninstall
brew uninstall doz
```

`doz uninstall` lists exactly what it will delete and asks once:

- **the store**: every sandbox, image, kernel and restore point, and the daemon's log and metrics;
- **the settings folder**: `doz.toml` and `agent-prompt.md`.

Keep either with `--keep-store` or `--keep-config`; `--yes` skips the question (without a terminal
and without `--yes` it refuses). A running daemon is stopped first; a running `doz ui` must be stopped
by you (Ctrl-C in its terminal). For a Homebrew install, the `doz` program itself is Homebrew's to
remove: `doz uninstall` says so and ends with the `brew uninstall doz` command.

It **never** touches:

- your project folders;
- your keychain. Remove accounts you added first if you want their keychain items gone:
  `doz account rm NAME` (it deletes the item `doz account add` made). `doz uninstall` names any left;
- Claude Code's own files and login.

## Start over: doz nuke

```sh
doz inventory        # what Dozable keeps on this Mac, where, and how big — changes nothing
doz nuke --dry-run   # what doz nuke would remove
doz nuke             # remove it all (asks first)
```

`doz nuke` puts this Mac back to a fresh install of Dozable and keeps `doz` installed. It lists each item with
its place and size, then asks once:

- **the store**: every sandbox, image, kernel, restore point and template, and the daemon's log and metrics;
- **the settings folder**: `doz.toml`, `agent-prompt.md`, and the update and usage records;
- **the download cache** (`~/Library/Caches/doz`);
- **the keychain items Dozable made**: your accounts' keys and the default GitHub key.

`--dry-run` lists and removes nothing; `--yes` skips the question. A running daemon is stopped first; a running
`doz ui` must be stopped by you (`doz ui stop`). Your next `doz` command starts
from the beginning: `doz onboard` or `doz ui`.

It **never** touches your workspace folders, the Mac's own Claude Code and Codex logins, or Apple's `container`
data. `doz inventory` prints the same list and changes nothing.

## Build from source (contributors)

The source is on GitHub (`dozable/dozable`). `make install-cli` builds and signs `doz` into
`~/.local/bin`; `make cli` builds a signed development copy. A source build is never updated by doz itself.
Don't have a Homebrew `doz` and a source-built one on your `PATH` at the same time. See the repository's README.

## Settings

| key | default | what it does |
|---|---|---|
| `store.path` | `~/Library/Application Support/doz` | Where the store lives (`--store`, `$DOZ_STORE`). |
| `daemon.always_on` | `true` | The daemon keeps running when nothing runs (`$DOZ_DAEMON_ALWAYS_ON`). |
| `daemon.idle_timeout_minutes` | `0` | With `daemon.always_on` off: minutes with nothing running before the daemon exits (`0` = never). |
| `updates.mode` | `notify` | `notify`, `auto` or `off` (`$DOZ_UPDATES`). |
| `updates.channel` | `stable` | `stable`, `beta` or `canary` — a Homebrew install's formula decides while it is not set. |

## Troubleshooting

| symptom | what to do |
|---|---|
| `brew install` says another doz formula is installed | One channel at a time: `doz upgrade --channel …` switches (or `brew uninstall` the other first). |
| "the update feed was ignored" / "do not verify" | Nothing is installed from it; doz keeps working. If it persists, check your network isn't rewriting `updates.dozable.com`. |
| `doz: command not found` | `brew list doz`, then open a new terminal window. |
| "this daemon's program … is gone — an upgrade removed it" | `doz daemon stop`, then run your command again. |
| "cannot boot a VM" or a message about the entitlement | `doz doctor`. Reinstall: `brew reinstall doz`. |
| Start over, keeping doz installed | `doz nuke`, then `doz onboard`. |
| Start over from nothing | `doz uninstall`, `brew uninstall doz`, then `brew trust --tap dozable/tap`, `brew install dozable/tap/doz` and `doz onboard`. |
