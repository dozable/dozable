# Bundling doz in an app

**Most people do not need this page.** If you want Dozable on your Mac, install the `doz` command with Homebrew
([Installing, upgrading and uninstalling](02-install-upgrade-uninstall.md)). This page is for people who build a Mac
app that runs sandboxes through Dozable, and carries `doz` inside the app to do it.

Every release of `doz` comes in two flavours, built from the same source at the same version:

| file on the releases page | what it is | who it's for |
|---|---|---|
| `doz-VERSION-macos-arm64.tar.gz` | the **command-line release** — what Homebrew installs | people |
| `doz-VERSION-macos-arm64-helper.tar.gz` | the **helper build** — the same host, made to live inside an app | app authors |

Each has its `.sha256` beside it, and a `.dSYM.zip` with its symbols (so a crash report from it can be symbolicated).

## Concepts

- **The host** is the `doz` process that owns a store's virtual machines and answers on `<store>/host.sock`. The
  helper build runs the very same host as the command-line release, speaking the same protocol: an app talks to it
  over that socket, as the `doz` command itself does. See [the host and its protocol](../DOZABLEKIT.md) (the section
  "The doz host": JSON lines, one request, progress events, one answer).
- **The helper build** is that host with the parts a person uses at a terminal left out. The app is its interface.
- **The layout contract** is the folder an app copies whole into its bundle. Within a minor version (all of
  `0.37.x`, say) nothing in it moves or is renamed.

## How the helper build differs

| | command-line release | helper build |
|---|---|---|
| the host, `host.sock`, its protocol, every sandbox operation | ✓ | ✓ the same |
| read-only commands (`doz ls`, `doz inspect`, `doz doctor`, `doz host status`, `doz --version`) | ✓ | ✓ |
| the web dashboard (`doz ui`, `doz ui --lan`) | ✓ | — not built in: `doz ui` says it is "not in this build" |
| the setup wizards (`doz onboard`, `doz init`) and `doz try` | ✓ | — not built in (the same answer) |
| updates itself (`doz upgrade`, the daily check, `updates.mode`) | ✓ | — never: `doz upgrade` refuses, and it never looks for updates. Your app updates it |
| anonymous usage statistics and `doz signup` | ✓ (you can turn them off) | — never: not built in, so it sends nothing. What your app sends is your app's choice |
| `RELEASE` file says | `public` | `helper` |
| the host's status reports `flavour` | `cli` | `helper` |
| the pinned Linux kernel inside | ✓ | ✓ |
| stripped, with its symbols published as a `.dSYM.zip` | ✓ | ✓ |
| signed with Dozable's Developer ID (team `KJ8QMLWB97`), notarised, the virtualization entitlement | ✓ | ✓ the same |

Both carry the pinned Linux kernel, so a new Mac's first sandbox needs no kernel download (it used to fetch a
release archive of about 0.6 GB to keep 16 MB of it). The first start of a store copies the kernel into the store and
checks it; nothing is downloaded from kata-containers.

## Get it and verify it

From the project's GitHub releases page (`dozable/dozable`), take the helper tarball and its `.sha256`, then:

```sh
shasum -a 256 -c doz-VERSION-macos-arm64-helper.tar.gz.sha256
tar -xzf doz-VERSION-macos-arm64-helper.tar.gz
codesign --verify --strict doz-VERSION-helper/libexec/doz/doz
codesign -dv doz-VERSION-helper/libexec/doz/doz 2>&1 | grep TeamIdentifier=KJ8QMLWB97
```

Pin the version AND the sha256 in your build: the helper runs with the virtualization entitlement, so a tarball
whose checksum or team does not match must stop your build.

## The layout contract

```
doz-VERSION-helper/
├── README.md                         what this is, and a link to this page
└── libexec/doz/                      copy this folder WHOLE into your app
    ├── doz                           the program (signed, with the virtualization entitlement)
    ├── VERSION                       its version, one line
    ├── RELEASE                       helper
    ├── DozableKit_DozableKit.bundle/ the small Linux programs each sandbox uses (deckhold, doznet, dozview, tmux)
    ├── kernels/vmlinux-6.18.15-186   the pinned Linux kernel (GPL-2.0, unmodified)
    └── licences/                     LICENSE, NOTICE, THIRD-PARTY-LICENSES.txt; kernel/: the kernel's source offer
```

`doz` finds everything beside its own (resolved) executable, so the folder works wherever it lands, as long as it
stays whole. The command-line release has the same `libexec/doz/` plus `bin/doz` (a link) and the dashboard's
bundle, `DozableKit_DozableWeb.bundle`.

## Rules for an app that carries it

1. **Copy `libexec/doz/` whole** to `YourApp.app/Contents/Resources/Helpers/doz/`. Not `Contents/MacOS/`: the host
   starts itself again from its own executable, and must find its parts beside it.
2. **Never re-sign it.** Its signature carries the virtualization entitlement; your app does not need that entitlement
   at all. Sign your app WITHOUT `--deep` (which would re-sign the helper and drop the entitlement).
3. **Replace it by rename, never in place.** Copy the new folder beside the old one and rename it over: a host still
   running the previous copy keeps its own file. Overwriting a running host's program makes macOS refuse its VMs.
4. **Give it its own store and its own settings.** Pass `--store` (or set `DOZ_STORE`) to a folder of your app's
   (`~/Library/Application Support/<your bundle id>/doz-store`, say), and set `XDG_CONFIG_HOME` to a folder of your
   app's, so it never shares a store or `doz.toml` with a person's own `doz`. Keep the store's path short: the socket
   path `<store>/host.sock` must fit in 103 bytes.
5. **One host per store.** The host holds `<store>/host.lock` for its whole life. Start it with
   `doz host start --store DIR`: it starts one detached (or finds the one already running) and answers with its
   status. While the lock is held, a host is there or is exiting: wait for `host.sock` to answer rather than start
   another process.
6. **Check whom you are talking to.** The status the host answers (the `ping` request, or `doz host status --json`)
   carries `version`, `protocolVersion` and `flavour`. Refuse a host whose version is not the one you carry, or whose
   `flavour` is not `helper` (a person's command-line `doz` pointed at your store), and say so.
7. **Updates are yours.** Ship a new helper with a new version of your app. The helper never replaces itself.

A minimal handshake over the socket:

```
→ {"v":1,"op":"ping"}
← {"ok":true,"result":{"version":"0.37.41","protocolVersion":1,"flavour":"helper","pid":4242,…}}
```

## The kernel and its source

Both tarballs carry Linux `vmlinux-6.18.15-186` exactly as kata-containers 3.28.0 builds it, checked against its
sha256 on every start. It is GPL-2.0: its provenance and Dozable's written offer of its source are in the tarball
(`libexec/doz/licences/kernel/`) and in the repository ([`Guest/kernel/PROVENANCE.md`](../../Guest/kernel/PROVENANCE.md)).
If you redistribute the helper, keep `licences/` with it — it is part of the layout for that reason.

## Settings

The helper reads the same settings as the command-line release (see [Settings reference](15-settings-reference.md)),
from `$XDG_CONFIG_HOME/doz/doz.toml`. `updates.mode` and `updates.channel` have no effect: it never updates itself.

## Troubleshooting

| symptom | what to do |
|---|---|
| "cannot boot a VM", or `doz doctor` says the entitlement is missing | The helper was re-signed (an app signed with `--deep`?). Copy it again from the tarball. |
| `doz upgrade` says "this doz belongs to …" | That is the helper build: the app that carries it updates it. |
| `doz ui` says it is "not in this build" | The helper has no dashboard. The `doz` command from Homebrew has it. |
| A wake fails with "this host's program was updated underneath it" | The helper's file was overwritten while its host ran. Replace it by rename (rule 3); `doz host stop`, then retry. |
