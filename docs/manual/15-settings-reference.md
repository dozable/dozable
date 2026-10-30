# Settings reference

This Mac's settings are in one file, **`~/.config/doz/doz.toml`** (under `$XDG_CONFIG_HOME` when that
is set). The file lists Dozable's own settings with a description and their default, commented out;
only the values you set are uncommented. A **recipe's** own settings — the settings of the agent it
installs: its `version`, `approvals`, `memory_mib`, `network`, and any the recipe declares — are a
`[recipes.VENDOR.PRODUCT]` block (`[recipes.anthropic.claude-code]`), written only while one of them is
set, so the file stays small however many recipes there are; `doz config show --agent ID` lists them.
The dashboard's **Settings** page shows and edits the same file, and its **Recipes** section lists the
recipes on this Mac.

## Where a value comes from

For each setting, the first of these that says something wins:

1. **a command-line flag** (for the settings that have one — `--store`, `--progress`, `--color`/`--no-color`,
   `doz create --cpus`, `doz create --approvals`, …);
2. **its environment variable** (`DOZ_STORE`, `DOZ_PROGRESS`, `DOZ_COLOR`, `DOZ_HOST_IDLE`, `DOZ_SCREEN_CAPTURE`,
   `DOZ_BOOT_LOGS`, `DOZ_SUBNET`, `DOZ_KERNEL`, `DOZ_KERNEL_CACHE`);
3. **the sandbox's own value** (a setting one sandbox can have, below);
4. **its project's** (`doz_project.yaml`: when the sandbox is made, and again at every `doz up`);
5. **this Mac's** (the file);
6. **the default** — the recipe's own, for a recipe's settings; Dozable's, for the rest.

`doz config show` names the source of every value, and the dashboard shows the same word as a badge:
**recipe** · **default** · **Mac** · **project** · **sandbox** · **env** · **flag**. A value fixed when a
sandbox is made (its agent's version, memory, network, its CPUs) is recorded in it with where it came
from; changing this Mac's value later moves no existing sandbox (`doz reset NAME` moves its version).

## Read and change settings

```sh
doz config                                  # Dozable's own settings: value, source, default — and the recipes in use
doz config show --all                       # every setting, every recipe's too
doz config get ui.theme                     # one value (--json adds its source and default)
doz config set ui.theme dark                # write it to this Mac's file (checked against its type first)
doz config unset ui.theme                   # back to the default (commented out again)
doz config init                             # write the file with every setting commented out
doz config show --agent claude-code         # one recipe's settings: value, source, the recipe's default
doz config set --agent claude-code version 2.1.290   # one of a recipe's settings, on this Mac
doz config path                             # where the file is
```

`--agent` takes a recipe's id (`claude-code`), a major (`opencode@2`) or its full name
(`anthropic/claude-code`).

In the dashboard: **Settings** lists Dozable's settings with their value, default, description and
source, and changes them in place (**Default** puts this Mac's value back to the default). Its
**Recipes** section lists the recipes in use (a sandbox runs the agent) and the ones installed (a baked
image of it is on this Mac, or you set one of its values); search the catalogue for the rest. A
recipe's page has its settings, its baked images, its sandboxes and **Uninstall**. A value set by an
environment variable, and the settings that name a folder on your Mac, are shown read-only there —
change them with `doz config set`.

### Per sandbox and per project

`sandbox.clipboard`, `sandbox.browser_bridge`, `sandbox.open_files`, `sandbox.ssh_agent`,
`sessions.tmux`, `sandbox.agent_sudo`, `sandbox.audio` and its agent's **`approvals`** can also be set for
one sandbox (sound only between `speakers` and `on` — whether it has sound at all is chosen when it is
made; see [Sound](23-sound.md)):

```sh
doz config show --sandbox my-app                          # what it overrides, what it follows, what was recorded
doz config set --sandbox my-app sandbox.clipboard off
doz config set --sandbox my-app approvals ask             # its agent asks before it acts, from the next session
doz config get --sandbox my-app sessions.tmux
doz config unset --sandbox my-app sandbox.clipboard       # follow the project, else this Mac, again
doz config set --project ~/code/my-app approvals ask      # the project's doz_project.yaml
```

Or when you create it (`doz create --clipboard off --browser-bridge off --open-files off --ssh-agent on --tmux --no-agent-sudo --sound on --approvals ask`),
or in its `doz_project.yaml` (`clipboard:`, `browser_bridge:`, `open_files:`, `ssh_agent:`, `tmux:`, `agent_sudo:`, `audio:`, `approvals:`).
The sandbox page's **Config** tab shows the same: its overrides first, with this Mac's value beside each
and **Follow the Mac**.

### The names before 0.37.34

The recipe settings had other names before 0.37.34 (`images.claude_code_version`, `claude.permissions`,
`images.claude-code.memory_mib`, …; the table below lists them). They still work: the file is read with them, and
`doz config get|set|unset` takes them and says the new name. The first change written after the upgrade
moves them to their new names and keeps the file as it was, once, as `doz.toml.0.37.bak` beside it. A
base with no agent (`python`, `go`) keeps the memory and network it had: `defaults.memory_mib` and
`defaults.network`, set from Claude Code's old values.

"Use GitHub as you" is a permission, not a setting: `doz net allow NAME github:as-you` (and
`github:push`), `doz create --github read|push`, `github:` in `doz_project.yaml` — see
[GitHub as you](18-github.md).

## About the file

- **The file is Dozable's.** `set`, `unset`, `init` and the Settings page rewrite it whole, atomically,
  readable only by you. Comments you add aren't kept.
- **A mistake never breaks Dozable.** An unknown key or a value of the wrong type is a warning (that line
  is ignored, the default applies). A file that doesn't parse at all is ignored — with the line that's
  wrong — and never overwritten until you fix it.
- **When a change applies** is part of each setting: at once, for the next command, the next sandbox
  created, the next session, the next start or wake, or after `doz host stop`.

## Not settable, on purpose

The dashboard's security limits and checks (session and link lifetimes, request and connection caps,
the Host/Origin/CSRF checks, the content policy); a browser terminal's one-use tickets and paste
limits; the guest programs; and any credential. `ui.terminals` can only take something away.

## Every setting

This table is generated from `doz config show` and checked against it on every build.

<!-- settings:begin -->
### `[ui]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `ui.boot_view_on_start` | `false` | boolean | at once | — | After Start the page stays on its Console tab (the kernel and vminitd), and marks the agent's tab when it is ready; false (the default): it switches to the agent's tab as soon as that has drawn its screen. |
| `ui.confirm_shutdown` | `true` | boolean | at once | — | Shut Down asks first (its dialog's "don't ask again" sets this to false). Reset and Remove always ask with a box to tick. |
| `ui.explain_tab_close` | `true` | boolean | at once | — | Closing an agent's tab returns to the sandbox's Home, which says the agent is still running and that End stops it (its "Don't say this again" sets this to false). false: Home does not say it. |
| `ui.nav_thumbnails` | `true` | boolean | at once | — | Hovering a session in the sidebar shows a screen icon; resting on it for half a second shows the session's live picture (moving to another session then shows its picture at once). false: no icon, no picture. |
| `ui.split_default` | `shell` | shell \| watch \| attach \| dialog | at once | — | What a terminal's Split opens: shell (a new shell session), watch (a read-only view of the left terminal's session), attach (a second, shared view of it), dialog (choose each time). |
| `ui.terminals` | `true` | boolean | at once | — | Terminals in the browser. false: the UI opens none and refuses a terminal ticket (Terminal.app still works). |
| `ui.terminal_title` | `{sandbox} · {session} · {time}` | a title with {sandbox} {session} {image} {time} {phase} ("" = leave the title alone) | at once | — | The title doz attach gives your terminal (window or tab) while attached, and a doz ui terminal's tab: {sandbox} {session} {image} {time} (this Mac's, HH:MM, refreshed each minute) {phase}. The terminal's own title comes back when you detach (where the terminal keeps a title stack: iTerm2, Ghostty, kitty, xterm). While doz sets it, a session's own title is not shown; "" leaves the title to the session. |
| `ui.terminal_font_size` | `13` | integer 9–32 | at once | — | The browser terminal's font size, in points (a terminal opened from now on). |
| `ui.theme` | `auto` | auto \| light \| dark | at once | — | The UI's colours: auto follows macOS. |
| `ui.density` | `comfortable` | comfortable \| compact | at once | — | The UI's spacing: comfortable, or compact — tighter rows, tabs, controls and page margins; the text stays the same size. |
| `ui.notifications` | `cards` | cards \| pills \| bell | at once | — | Where the UI shows its notifications, in its top right corner: cards (a bell, and a column hanging below it, each with its full text and buttons and, for a success, a countdown that waits while the pointer is on any card), pills (one line each along the top, the newest at the right; click one for the rest), or bell (a count; the newest shows beside it for a few seconds; click for the list). Successes go by themselves; a failure stays until you close it. The Notifications page lists every one this tab showed. |
| `ui.details_open` | `true` | boolean | at once | — | A sandbox's page shows its details panel (restore points, network, keys) beside the terminals; false: collapsed. |
| `ui.allow_secret_entry` | `true` | boolean | at once | — | The web UI takes an Anthropic API key or a Claude setup token in a masked field — an account (the setup wizard, Accounts & keys: stored exactly as doz account add stores it, the login keychain) or a sandbox's own key (its page: exactly as doz key set does, held by the host) — sent once, in a request body. false: the pages show the command instead. The UI can turn this off, never on. |
| `ui.open_browser` | `auto` | auto \| always \| never | next command | — | When doz ui opens a browser tab: auto (only when no page of this store's UI is open — an open page reconnects by itself instead), always (every start), never (it prints the address; doz ui link opens a page). --open and --no-open override it. |
| `ui.port` | `0` | integer 0–65535 | ui-restart | `$DOZ_UI_PORT`, `--port N` | The ONE port the dashboard (doz ui) listens on — this Mac's browser at http://127.0.0.1:<port>, and with ui.lan your other browsers at http://<this Mac>.local:<port>. 0 = automatic: without ui.lan, the port this store's last doz ui had when it is free (else one the system picks, and doz ui says so); with ui.lan, serve.port (7443), which never moves. Or a fixed port 1024–65535 (doz ui refuses to start, naming the program, when another holds it). An installed dashboard app belongs to one port: keep it fixed for one. |
| `ui.lan` | `false` | boolean | ui-restart | `$DOZ_UI_LAN`, `doz ui --lan \| --no-lan` | Also serve the dashboard to the other browsers of your network (every network interface of this Mac and Tailscale, never a sandbox's network) on the same port: each gets in once with an invite (doz ui share). false (the default): this Mac only. Where it listens and your reverse proxy: the serve.* settings. |
| `ui.grid_live_tiles` | `12` | integer 1–12 | at once | — | No longer used — every session picture is live (painted from its screen, no terminal per picture). Kept so that an older settings file still reads without a warning. |
| `ui.grid_tile_size` | `medium` | small \| medium \| large | at once | — | All sessions: the size of a tile. |
| `ui.grid_refresh_ms` | `500` | integer 200–10000 | at once | — | How often the session pictures (All sessions, All sandboxes, a sandbox's Home) are brought up to date, in milliseconds. Only pictures on screen are asked for, only while the browser tab is shown, and a screen that did not change costs almost nothing. Lower looks livelier and costs more. |
| `ui.batch_concurrency` | `3` | integer 1–8 | at once | — | How many starts, wakes, resumes, sleeps, hibernations and shut-downs the dashboard runs at once; the others wait their turn, shown as queued with a Cancel. One you start on a single sandbox (or by typing in its terminal) goes ahead of those started for many at once. A pause, and a resume from a pause, never wait. A change applies as soon as one ends. |
| `ui.progress` | `animated` | animated \| plain | at once | `$DOZ_PROGRESS`, `--progress auto\|plain` | How a start, wake or bake shows its progress — in the web UI's boot view and in the CLI on a terminal: animated (a spinner on the step under way, download bars, the output's last lines) or plain (one line per step, and a summary line per download). Not a terminal, --json or NO_COLOR: always plain. |
| `ui.color` | `auto` | auto \| always \| never | at once | `$DOZ_COLOR`, `--color auto\|always\|never, --no-color` | Colour in the CLI's output: auto (on a terminal, unless NO_COLOR is set, TERM is dumb, or with --json or -q), always (even into a pipe or a file), never (plain text; the layout and the symbols stay the same). The dashboard has its own theme (ui.theme). |

### `[serve]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `serve.port` | `7443` | integer 1024–65535 | ui-restart | `$DOZ_SERVE_PORT`, `doz ui --lan --port N` | The dashboard's port with ui.lan while ui.port is 0 (automatic) — an earlier name for it: ui.port, when set, wins. It stays the same (devices, an installed app and a bookmark belong to it): when another program holds it, doz ui refuses and names it. |
| `serve.bind` | `lan` | lan \| loopback \| the Mac's addresses, comma-separated | ui-restart | `$DOZ_SERVE_BIND`, `doz ui --lan --bind lan\|loopback\|ADDRESSES` | Where the dashboard listens for your other browsers with ui.lan: lan (every network interface of this Mac and Tailscale — never a sandbox's network), loopback (127.0.0.1 and ::1 only: for a reverse proxy on this Mac), or this Mac's own addresses separated by commas (for a reverse proxy elsewhere on your network). This Mac's own browser is served at 127.0.0.1 in every case. |
| `serve.public_origins` | `""` | origins like https://doz.home.example, comma-separated ("" = none) | ui-restart | — | The addresses your reverse proxy serves the dashboard at, like https://doz.home.example (comma-separated). A browser may use one only through a proxy listed in serve.trusted_proxies. Over https, keys and tokens may be typed in the dashboard; over plain http they never are (except in this Mac's own browser). |
| `serve.trusted_proxies` | `""` | addresses or networks like 127.0.0.1, 192.168.1.0/24, comma-separated ("" = none) | ui-restart | — | The reverse proxies whose X-Forwarded-Proto, X-Forwarded-Host and X-Forwarded-For the dashboard believes — their addresses or networks, comma-separated (a proxy on this Mac: 127.0.0.1, ::1). From anyone else those headers are ignored. |
| `serve.advertise` | `true` | boolean | ui-restart | — | With ui.lan, announce the dashboard on your network with Bonjour ("Dozable on <this Mac>", http://<this Mac>.local:<port>), so other Macs and phones can find it. |

### `[host]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `host.idle_timeout_minutes` | `5` | integer 0–10080 | after `doz host stop` | `$DOZ_HOST_IDLE`, `doz host start --idle-timeout` | Minutes with nothing running before the host exits; 0 = never. |
| `host.screen_capture_minutes` | `5` | integer 0–1440 | after `doz host stop` | `$DOZ_SCREEN_CAPTURE` | Every this many minutes, save the screen of each running sandbox's sessions that printed something since (what a sleep or hibernation falls back on); 0 = only when it pauses, sleeps or hibernates. |
| `host.boot_logs_kept` | `5` | integer 1–50 | next boot | `$DOZ_BOOT_LOGS` | How many boots of each sandbox to keep (its steps and kernel console — the web UI's Boot log, doz console --boot N); the oldest goes. |
| `host.keepalive` | `false` | boolean | a store that hasn't chosen | — | Near a Mac login's expiry, while a sandbox uses it and no Claude Code runs, the host runs the Mac's claude once to renew it. |

### `[store]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `store.path` | `~/Library/Application Support/doz` | path ("" = automatic) | next command | `$DOZ_STORE`, `--store` | The store: images, kernels, sandboxes and the host's files. |

### `[defaults]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `defaults.cpus` | `2` | integer 1–64 | new sandboxes | `doz create --cpus` | CPUs of a new sandbox. |
| `defaults.memory_mib` | `2048` | integer 256–262144 | new sandboxes | `doz create --memory` | Memory (MiB) of a new sandbox whose image has no agent (a base alone: python, go). A recipe's sandboxes have their recipe's own (doz config show --agent ID), the lab its own (images.lab). |
| `defaults.network` | `agent` | agent \| bake \| locked \| open \| nat \| none | new sandboxes | `doz create --network` | The network of a new sandbox whose image has no agent: agent, bake, locked, open (proxied presets), nat or none. |
| `defaults.nat_subnet` | `""` | IPv4 subnet, a.b.c.d/nn ("" = a free one) | new sandboxes | `$DOZ_SUBNET`, `doz create --subnet` | The vmnet subnet of a new --network nat sandbox. |
| `defaults.image` | `lab` | lab \| claude-code \| pi \| codex, or an agent or tool's id (doz try lists them) | new sandboxes | `doz create --image` | The image of a new sandbox when none is named (doz up NAME, doz init, the UI's New sandbox). doz onboard writes the one you chose. |
| `defaults.base` | `node` | node \| python \| go \| rust \| java \| ruby \| dotnet \| debian \| ubuntu \| alpine | new sandboxes | `doz try --base` | The base image of this store: every tool you try (Quick try, doz try, the setup's first sandbox) is added to it as a layer when no base is named, so a second tool downloads nothing more. doz onboard sets it. New sandbox and doz_project.yaml keep a tool's own default base unless you choose one. |
| `defaults.projects_dir` | `~/doz-workspaces` | path ("" = automatic) | new sandboxes | — | The base folder of new sandboxes' workspaces: the web UI's New sandbox and Quick add, and doz new, share <projects_dir>/<sandbox name> (created when missing, like any workspace). doz create is isolated unless --workspace; doz init uses the folder it runs in. In the web UI, Settings › Choose… sets it with the Mac's folder picker. |
| `defaults.account` | `mac` | mac \| none | a store that hasn't chosen | — | The Anthropic account of a store that has not chosen one: mac (this Mac's Claude Code login) or none. doz account default decides for a store once it has. |
| `defaults.permissions` | `standard` | standard \| locked \| open, or permissions like +web,-error-reports (doz net permissions) | new sandboxes | `doz create --allow / --network` | What a new sandbox's agent may do (its network, as permissions — doz net permissions): standard (talk to its AI model, update itself, install system packages and its base's language packages, use GitHub, send error reports), locked (its AI model only), open (everything, the web included), or standard with changes like +web,-error-reports. Stored by name: a Dozable update that adds a host to a permission reaches every sandbox that has it. |
| `defaults.github` | `off` | off \| read \| push | new sandboxes | `doz create --github off\|read\|push` | "Use GitHub as you" for new sandboxes: off, read (git and gh signed in as you on GitHub, read-only) or push (also push and make changes) — the Access step's choice (doz access set --github). A sandbox can differ: doz create --github, github: in doz_project.yaml, or its permissions later (doz net allow\|deny NAME github:as-you). Proxied sandboxes only. |

### `[agent]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `agent.prompt` | `true` | boolean | next session | — | Tell the agent where it runs: a short facts block appended to its system prompt (the sandbox, its /workspace share, the network, credentials) and the doz skill, written at every session start. Your own template: agent-prompt.md beside this file. |

### `[updates]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `updates.mode` | `notify` | off \| notify \| auto | next command | `$DOZ_UPDATES` | Updates: notify (at most once a day, and when doz ui opens, look for a newer doz and say how to upgrade — one line on a terminal, a banner on the dashboard), auto (also install it: brew upgrade, or the signed download for a tarball install — only while no sandbox runs and no session is attached, else it notifies; then: restart to apply, doz host restart), or off (never look). Never a downgrade; a feed that does not verify is ignored. |
| `updates.channel` | `stable` | stable \| beta \| canary | next command | — | Which releases you are offered: stable, beta (beta and stable) or canary (every build, first). A Homebrew install's own formula (doz, doz-beta, doz-canary) decides while this is not set; doz upgrade --channel switches both. |

### `[telemetry]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `telemetry.send_anonymous_usage_stats` | `true` | boolean | next command | `$DOZ_SEND_ANONYMOUS_USAGE_STATS`, `--no-send-anonymous-usage-stats / --send-anonymous-usage-stats` | Official builds send anonymous usage statistics: at most once a day, counts and ranges about how Dozable itself is used (commands by name, failures by exit code, which agents, bases and network presets new sandboxes use, setup sizes as ranges, start and wake times rounded to 50 ms, how long sandboxes ran and slept as ranges, which features were used, this Mac's macOS version, chip family, memory and cores as ranges) with a random install id — never a name, path, host, command argument, file or anything from inside a sandbox. false (or DO_NOT_TRACK=1, or --no-send-anonymous-usage-stats on one command) sends nothing and records nothing. doz telemetry show prints exactly what would be sent. Builds from the open-source repository send nothing whatever this says. |

### `[resources]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `resources.clean_unused_days` | `30` | integer 1–3650 | at once | — | Clean up (the Resources page, doz resources clean) removes a baked image no sandbox was created from in this many days; it is baked again when next needed. |

### `[sandbox]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `sandbox.agent_sudo` | `true` | boolean | next session | `doz create --no-agent-sudo / --agent-sudo` | The agent (the image's user in claude-code and pi sandboxes) has passwordless sudo inside its sandbox, so it can install system packages (sudo apt-get install …). The VM, the network policy and the absent credentials are the boundary — root inside reaches no more than the agent does. Applied at every boot and every agent session start (no image is rebuilt); a sandbox's own choice (doz create --no-agent-sudo, agent_sudo in doz_project.yaml) wins over this. |
| `sandbox.timezone` | `mac` | mac, or a time zone like Australia/Sydney | next start or wake | — | The sandboxes' time zone: mac (this Mac's, read again at every boot and wake — a laptop that travels while a sandbox sleeps is followed) or a zone like Australia/Sydney. Written to the guest's /etc/localtime; the agent's facts say it. |
| `sandbox.clipboard` | `write` | write \| off | at once | `doz create --clipboard write\|off` | The clipboard bridge: a program in a sandbox that copies (OSC 52 — Claude Code, vim, tmux) puts the text on this Mac's clipboard, and every copy shows a notice (SANDBOX copied N chars) in doz attach and doz ui. At most 1 MiB a copy and 10 copies in 10 s. A sandbox can never READ the Mac clipboard. The risk: an agent could put a command there for you to paste — off turns the bridge off (copies are dropped, and said). A sandbox's own choice (doz config set --sandbox NAME, clipboard in doz_project.yaml) wins over this. |
| `sandbox.browser_bridge` | `on` | on \| off | at once | `doz create --browser-bridge on\|off` | The browser bridge: xdg-open (and $BROWSER, open, sensible-browser) in a sandbox opens an http or https URL in this Mac's default browser, with a notice every time (at most 3 in 10 s). A sign-in whose redirect is the sandbox's localhost (Claude Code's /login) gets that port forwarded from the Mac into the sandbox for up to 10 minutes, so the login completes. Never file: or other schemes, never the Mac's own localhost. off: nothing opens (said). A sandbox's own choice (doz config set --sandbox NAME, browser_bridge in doz_project.yaml) wins over this. |
| `sandbox.open_files` | `on` | on \| off | at once | `doz create --open-files on\|off` | Open workspace files on this Mac: xdg-open PATH (and open PATH, doz-open PATH) in a sandbox opens a document from its /workspace in the Mac's default app — an html page in your browser, markdown in your editor — or a folder (the workspace itself, open .) in the Finder, and doz-open --reveal PATH shows a file selected in its folder; a notice every time (at most 3 in 10 s). Only the shared folder's own files (a link or .. that leads out is refused), only documents (html, md, pdf, images, txt, csv, json, yaml, xml…) — never an app or package folder, a script, an installer or an executable. An isolated sandbox has no file to open. An app other than the default only when it is in bridges.open_apps. off: nothing opens (said). A sandbox's own choice (doz config set --sandbox NAME, open_files in doz_project.yaml) wins over this. |
| `sandbox.ssh_agent` | `off` | off \| on | at once | `doz create --ssh-agent on\|off` | Forward this Mac's SSH agent into the sandbox (proxied sandboxes): ssh and git over SSH there can ask your agent to sign — your keys never enter the sandbox — and only github.com:22 is reachable over SSH. A notice on first use. While it is on, the agent can authenticate as you to github.com. A sandbox's own choice (doz create --ssh-agent on, ssh_agent in doz_project.yaml, doz config set --sandbox NAME) wins over this. |
| `sandbox.dotfiles` | `""` | a git repository's https:// URL, or a folder on this Mac that is one ("" = none) | new sandboxes | `doz create --dotfiles URL\|PATH\|none` | Your dotfiles in every new sandbox: a git repository (https://github.com/you/dotfiles — fetched on this Mac with its own git login, so a private one works and no credential enters the sandbox) or a folder on this Mac that is a git repository. A sandbox gets the commit it was made at, recorded; doz dotfiles NAME --update moves it on. At its first start, as its user: the repository's install script runs (the first of install.sh, install, bootstrap.sh, bootstrap, script/bootstrap, setup.sh, setup, script/setup — at most 5 minutes, its output in the boot log), or, with none, every dotfile and dot-folder at the top of the repository is linked into the home — never over a file that is there (only over the image's stock copy, kept as NAME.doz-stock), never over Dozable's own (the agents' settings and launchers). doz asks once per repository and commit before it is applied — it is code that runs in the sandbox. "" (the default): none. A sandbox's own choice (doz create --dotfiles, dotfiles in doz_project.yaml) wins over this. |
| `sandbox.audio` | `off` | off \| speakers \| on | new sandboxes | `doz create --sound off\|speakers\|on (--audio = on)` | Sound in new sandboxes: off, speakers (this Mac's speakers) or on (its speakers and microphone). A sandbox with sound has a sound device and boots Dozable's sound kernel, so it is chosen at create; its own choice (doz create --sound, New sandbox › Sound) wins over this. Later a sandbox can move between speakers and on (doz config set --sandbox NAME sandbox.audio on), from its next start. It records from the Mac's microphone only if macOS allowed it before the sandbox started (else silence); sandbox.microphone_ask says when doz asks. |
| `sandbox.microphone_ask` | `first_recording` | first_recording \| first_start | next start or wake | — | When doz asks macOS about the microphone for a sandbox whose sound is on, while macOS has no answer: first_recording (when a program in it first records — that recording is silent; allow, then Shut Down and Start the sandbox) or first_start (when it starts, waiting for your answer). |

### `[sessions]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `sessions.tmux` | `false` | boolean | next session | `doz create --tmux / --no-tmux` | Run each new session inside tmux (within Dozable's own session holder, so saved screens, sleep and wake, browser terminals and Ctrl-] detach keep working): tmux's windows, panes and copy mode, its status bar and prefix key (Ctrl-b). tmux takes the mouse, and the kitty keyboard protocol and modifyOtherKeys do not fully pass through it; the session's exit code is tmux's. It is Dozable's own tmux 3.8, copied into the sandbox on every base (the image's tmux is left as it is), so tmux reports your terminal's light or dark theme to the programs in it; a session already running in the image's tmux keeps it until it ends. A sandbox's own choice (doz create --tmux, tmux: true in doz_project.yaml, doz config set --sandbox) wins over this. |

### `[bridges]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `bridges.open_apps` | `""` | app names, comma-separated, like "Typora, Visual Studio Code" ("" = none) | at once | — | The Mac apps a sandbox may name to open a workspace file in (doz-open --app NAME FILE, or open -a NAME FILE in the sandbox), comma-separated — e.g. "Typora, Visual Studio Code". Empty: a file opens only in its default app, and naming an app is refused. Never a path, only an app's name. For every sandbox. |

### `[workspace]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `workspace.ignore_mode` | `lock` | lock \| hide | next start or wake | `doz create --ignore-mode lock\|hide` | What a .dozignore at the root of a sandbox's workspace folder does to the paths it lists (Docker's .dockerignore syntax): lock (they stay listed, shown with no permissions, and every read, write, rename or delete of them is refused — so a program that bumps into one by name sees why) or hide (they are not there at all). A .dozreadonly beside it (same syntax) makes paths visible but read-only; doz_project.yaml, .git/hooks and the two rule files are read-only too. Without either file the folder is shared as it is. A convenience mask, not a security boundary: root in the sandbox can get around it. A sandbox's own choice (doz create --ignore-mode, ignore_mode in doz_project.yaml, doz config set --sandbox NAME) wins over this. |
| `workspace.view` | `on` | on \| off | next-start | `doz create --workspace-view on\|off` | How a sandbox's workspace folder reaches it. on: through Dozable's live view of the folder, so a program working in /workspace (an agent, a shell) keeps its folder when the sandbox wakes from hibernation or after a host restart. The view costs a little: the first scan of a big folder after a start or a wake is slower (e.g. git status on a large repository, or find), later ones are about as fast as without it. off: the folder is shared directly (a little faster) — but a program working inside /workspace loses its folder at such a wake and must be restarted (Codex says "invalid cwd"). A folder with a .dozignore or .dozreadonly always uses the view. Changes take effect at the sandbox's next start. A sandbox's own choice (doz create --workspace-view, workspace_view in doz_project.yaml, doz config set --sandbox NAME) wins over this. |

### `[github]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `github.credentials` | `gh` | gh \| key \| off | at once | — | Where "Use GitHub as you" (a permission, off by default) gets your GitHub login: gh (this Mac's gh login, read when used — gh auth token — and kept in memory a few minutes, never written anywhere; gh auth logout revokes it), key (only a token you give a sandbox with doz key set NAME --github — a fine-grained token limited to some repositories is best), or off (never, even with the permission on). The sandbox only ever sees a placeholder; Dozable's proxy puts the real token in on the way to GitHub. |

### `[images.lab]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `images.lab.memory_mib` | `1024` | integer 256–262144 | new sandboxes | `doz create --memory` | Memory (MiB) of a new lab sandbox (a template follows the image it was saved from). |
| `images.lab.network` | `bake` | agent \| bake \| locked \| open \| nat \| none | new sandboxes | `doz create --network` | The network of a new lab sandbox: agent, bake, locked, open (proxied presets), nat or none. |

### `[kernel]`

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `kernel.path` | `""` | path ("" = automatic) | new sandboxes | `$DOZ_KERNEL` | An explicit Linux kernel for new sandboxes ("": the pinned kernel, fetched into the cache). |
| `kernel.cache` | `""` | path ("" = automatic) | new sandboxes | `$DOZ_KERNEL_CACHE` | Where the pinned kernel is cached ("": the store's own); share one between stores. |

### `[recipes.VENDOR.PRODUCT]` — every recipe's own

Every recipe's agent has these, each recipe with its own defaults (`doz config show --agent ID` lists one; the descriptions are Claude Code's). A recipe may declare more of its own: Codex's `keep_alive`.

| key | default | values | applies | overridden by | what it does |
|---|---|---|---|---|---|
| `recipes.VENDOR.PRODUCT.version` | `latest` | latest, or an exact version like 2.1.227 | new sandboxes | `doz create --agent claude-code@VERSION` | The Claude Code a new sandbox of this recipe gets (and every base's baked image of it): latest (looked up when its image is baked, then installed at that exact version, integrity-checked; a newer one is only said — doz image bake rebuilds when you choose), or an exact version like 2.1.227. A sandbox keeps the version it was made with; doz reset NAME moves it to the current one. |
| `recipes.VENDOR.PRODUCT.approvals` | `skip` | skip \| ask | next session | `-e DOZ_CLAUDE_PERMISSIONS=… on run/exec, --approvals on create` | Claude Code's own approval prompts: skip them (the sandbox is the boundary) or ask, as on a Mac. A sandbox (doz config set --sandbox NAME approvals ask) or its project (approvals: in doz_project.yaml) can choose its own. |
| `recipes.VENDOR.PRODUCT.memory_mib` | `2048` | integer 256–262144 | new sandboxes | `doz create --memory` | Memory (MiB) of a new sandbox of this recipe (a template follows the image it was saved from). |
| `recipes.VENDOR.PRODUCT.network` | `agent` | agent \| bake \| locked \| open \| nat \| none | new sandboxes | `doz create --network` | The network of a new sandbox of this recipe: agent, bake, locked, open (proxied presets), nat or none. |
| `recipes.openai.codex.keep_alive` | `false` | boolean | at once | — | Codex sandboxes on the account mac (this Mac's own Codex login): when its access token is about to expire and a sandbox used it in the last 15 minutes, run this Mac's codex doctor once — no model call — which renews the login the way Codex itself does. Off: the login renews only while Codex (the app or a codex session) runs on this Mac; when it has expired, Codex in a sandbox says so. |

### The names before 0.37.34 (still read, and taken by `doz config`)

| old name | now |
|---|---|
| `images.ID_version` | `recipes.VENDOR.PRODUCT.version` |
| `ID.permissions` | `recipes.VENDOR.PRODUCT.approvals` |
| `images.ID.memory_mib`, `images.ID.network` | `recipes.VENDOR.PRODUCT.memory_mib`, `.network` (Claude Code's, `images.claude-code.memory_mib` and `images.claude-code.network`, also seed `defaults.memory_mib`, `defaults.network`) |
| `images.claude_code_version` | `recipes.anthropic.claude-code.version` |
| `claude.permissions` | `recipes.anthropic.claude-code.approvals` |
| `images.pi_version` | `recipes.earendil-works.pi.version` |
| `images.codex_version` | `recipes.openai.codex.version` |
| `codex.permissions` | `recipes.openai.codex.approvals` |
| `codex.keep_alive` | `recipes.openai.codex.keep_alive` |

<!-- settings:end -->

## Environment variables

| variable | overrides | |
|---|---|---|
| `DOZ_STORE` | `store.path` | the store folder |
| `DOZ_PROGRESS` | `ui.progress` | `animated` or `plain` progress |
| `DOZ_COLOR` | `ui.color` | `auto`, `always` or `never` colour in the CLI |
| `DOZ_HOST_IDLE` | `host.idle_timeout_minutes` | host idle timeout, minutes (fractions allowed) |
| `DOZ_SCREEN_CAPTURE` | `host.screen_capture_minutes` | how often screens are saved |
| `DOZ_BOOT_LOGS` | `host.boot_logs_kept` | boots kept per sandbox |
| `DOZ_SUBNET` | `defaults.nat_subnet` | subnet of a new `nat` sandbox |
| `DOZ_KERNEL` · `DOZ_KERNEL_CACHE` | `kernel.path` · `kernel.cache` | an explicit kernel · a shared kernel cache |
| `XDG_CONFIG_HOME` | — | where `doz/doz.toml` is (default `~/.config`) |
| `NO_COLOR` | — | no colour and plain progress, unless `--color always` (or `ui.color = "always"`) asks for it |
