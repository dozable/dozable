# The menu bar app

Dozable's daemon is the background process that runs your sandboxes. The menu bar app, **Dozable.app**, puts it in
your Mac's menu bar: whether it is running, which version, how many sandboxes are up — and Start, Stop, Restart and
Open Dashboard, one click each. It has no chat and no settings of its own; everything else is `doz` and the dashboard.

It comes with doz (Homebrew and the release tarball carry it) and does nothing until you install it.

## Install it

```sh
doz app install
```

This copies the app that came with your doz into `/Applications` (into `~/Applications` when you cannot write to
`/Applications`). Then open **Dozable** from Finder, Launchpad or Spotlight — or install and open in one go:

```sh
doz app install --open
```

It has no Dock icon and no window: look for its icon in the menu bar, at the top right of the screen. It is signed
and notarised by Dozable, so macOS opens it without a warning.

`doz app install` checks the copy before it installs it (its signature, that it is Dozable's, that it is the version of
your doz) and then swaps it in whole — a copy that is already running keeps running the version it started with until
you open it again. `--dest DIR` installs it somewhere else.

## What the menu shows

The first line is the daemon's state:

| the menu says | what it means |
|---|---|
| Daemon running · 0.50.7 | It runs, and this is its version. The next line says whether it stays running with nothing open ("Always on") and how many sandboxes run. |
| Daemon stopped | Nothing runs. **Start Daemon**, or any `doz` command, starts it. |
| Daemon stopped until a doz command starts it | You stopped it with `doz daemon stop` (or the menu): it stays stopped until you start it — "or your next login" when a login item starts it at login. |
| Daemon started from ssh — it cannot read your Keychain | It was started over ssh, where your login Keychain is locked, so it cannot use your Claude login. **Restart Daemon** starts a new one from your desktop session, which can. |
| Daemon runs an older build (0.50.6) — Restart to update | doz was upgraded while the daemon ran. **Restart Daemon** switches to the new version. |
| doz is not installed | The app found no doz (it looks at `/opt/homebrew/bin/doz`, `/usr/local/bin/doz` and `~/.local/bin/doz`). **How to Install doz…** opens this manual's install page. |
| doz 0.50.3 is older than this app needs | Upgrade doz (`doz upgrade -y`). Meanwhile the menu still shows the state and offers Start, Stop, Restart and Open Dashboard. |

"Starts at login (set by doz)" appears when you turned on doz's login item (`doz daemon login-item on`).

The icon is filled while the daemon runs, outlined when it is stopped, a warning triangle when a Restart is due, and
hollow when there is no doz.

## What it does

- **Start Daemon** — the same as `doz daemon start`.
- **Stop Daemon…** — the same as `doz daemon stop`. When sandboxes are running it asks first: they hibernate, and wake
  when you use them again. Sessions on this Mac keep running.
- **Restart Daemon** — the same as `doz daemon restart`: stop (sandboxes hibernate), then start on the current version.
- **Open Dashboard** — the same as `doz ui --detach --open`: the dashboard opens in your browser, signed in. The
  sign-in link goes straight from doz to your browser; the app never sees it.
- **Quit Dozable Menu** — quits the app only. The daemon and your sandboxes keep running.

The app runs `doz` for each of these, so it does exactly what the command does — including refusing what the command
refuses (it shows doz's reason in the menu). It never starts the daemon just by looking: the state is read with
`doz daemon status`, which never starts one.

The menu refreshes when you open it (and every two seconds while it is open), once a minute while it is closed, when
your Mac wakes, and after every action.

## Updates

The app updates with doz. After `doz upgrade` (or `brew upgrade`), the menu shows the new version and then offers
**Update Menu Bar App (old → new)**: it installs the copy that came with the new doz and reopens the app. The same,
from Terminal:

```sh
doz app install --open
```

## Remove it

```sh
doz app uninstall
```

This quits the app and removes it from `/Applications` (and `~/Applications`). The daemon keeps running. `doz
uninstall`, which removes all of Dozable, removes the app too.

## Where to look

```sh
doz app status        # the copy that came with doz, where it is installed, whether it runs
```

The app writes one line per doz command it runs to the system log — the command and its result, nothing else. To read
it: `log show --predicate 'subsystem == "com.dozable.app"' --last 1h`.

From an ssh session you can see what the menu would show without the screen:

```sh
/Applications/Dozable.app/Contents/MacOS/Dozable --dump-menu
```

## Not yet

- It does not start at login by itself: open it from Finder, or add it under System Settings › General › Login Items.
  (doz's own login item, `doz daemon login-item on`, starts the daemon at login — not the menu.)
- It shows the default store only (the one `doz` uses when you give it no `--store`).
- Its icon is a placeholder.
