# The dashboard (`doz ui`)

`doz ui` is Dozable in your browser: every sandbox with a live terminal, its restore points and
permissions, your images, accounts, disk use and settings. It does almost everything the command line
does, and a few things are easier there — watching many sessions at once, or seeing what an agent was
refused and allowing it with one click. It runs on your Mac only; nothing else can reach it.

## Concepts

- **One dashboard per store.** Running `doz ui` again reuses the one that runs.
- **A one-use sign-in link.** `doz ui` opens your browser with a link that works **once**, for **five
  minutes**, and signs that browser in — it stays signed in until you sign out or don't use it for
  **14 days** (each visit renews it), so an installed dashboard app opens signed in. Nobody else can sign
  in without a link.
- **An app, if you like.** Install it from Chrome or Safari and it opens in its own window with its own
  icon (see [Install it as an app](#install-it-as-an-app)).
- **A client of the daemon**, like the command line. Opening the dashboard doesn't start the daemon;
  any action you take does, as a command would.

## Start it

```sh
doz ui                    # serve it and open it in your browser (the same as doz ui start)
doz ui --print-url        # print the link instead of opening a browser
doz ui link               # another browser or tab on the dashboard that runs
doz ui restart            # restart the running dashboard as the doz installed now: open pages carry on by themselves
doz ui --new-link         # sign every page out and make a new link
doz ui --detach           # run it in the background (no terminal needed), open it, and return
doz ui stop               # stop the running dashboard — a detached one, or one in another terminal
```

Stop it with **Ctrl-C** in its terminal, or `doz ui stop` from any terminal. `doz ui --detach` keeps it running
without a terminal (its log is the file ui.log in the store) until `doz ui stop`; `doz ui restart` keeps it in the background. The address is `http://127.0.0.1:PORT` — this Mac only. The
port is the setting `ui.port`: `0` (the default) means the port this store's last dashboard used, when
it's free, so a page left open reconnects by itself — still signed in — when you start `doz ui` again,
and no new tab opens. If another program took that port, `doz ui` says which and listens elsewhere. For
an installed app, fix the port, because an app belongs to one address:

```sh
doz config set ui.port 7443   # then: doz ui restart
doz ui start --port 7444      # one run on another port
```

A fixed port that another program holds is never silently swapped: `doz ui` refuses to start and names
the program. After `doz ui restart` onto a new port, the dashboard opens there in a new tab and the old
page says where it went (a browser rule keeps a page from following by itself).

**After an upgrade.** `doz ui restart` (and **Restart dashboard** on the page) always starts the doz installed
now — after `brew upgrade`, the new version, even when the dashboard was started from the one before. A dashboard
in the background with no page open restarts into a new doz by itself within a minute of the upgrade; with a page
open it waits for you: the status card says the dashboard is older and offers **Restart dashboard**.

**When a tab opens:** only when none of the dashboard's pages is open (the setting `ui.open_browser`:
`auto`). Set it to `always` or `never`, or use `--open` / `--no-open` for one run.

Treat a printed link like a password: anyone with it can sign in to your dashboard for those five
minutes.

## Install it as an app

- **Chrome (or Edge):** on the dashboard, the address bar's install icon or **⋮ › Cast, save and share ›
  Install page as app…** — *Install Dozable – john-mac-studio* (the app is named for its Mac: its local hostname, from
  System Settings › General › Sharing). It opens in its own window, with the Dozable icon in the
  Dock and in ⌘-Tab, and shares Chrome's sign-in. Each Mac's dashboard is its own app — install the one of each
  Mac you use (from another computer, with [the LAN option](25-doz-serve.md)) and the windows are titled apart.
- **Safari:** **File › Add to Dock**. A Safari web app keeps its own cookies, so it opens on the
  dashboard's sign-in: paste a link from `doz ui link --print-url` into its field.

When `doz ui` isn't running, the app (or a reload) shows **Dozable isn't running on this Mac** with what to
run, instead of the browser's error page; it comes back by itself, on the view it was on, as soon as
`doz ui` answers. The app needs nothing to stay running in the background.

## The pages

![The Sandboxes page](images/dashboard-sandboxes.png)

The sidebar starts with the menu button, the Dozable mark, its name with this Mac's name, and the store it shows — that
name is the machine picker (see [Your other Macs](#your-other-macs-the-machine-picker)). The top
right corner of the window is where notifications appear (see [Notifications](#notifications)). Each
page's title stays at the top as the page scrolls, and a table's column headings stay under it. The
sidebar has four parts, top to bottom: **Home** (your workspaces — the page the dashboard opens on), **Chat** (while
chat is on), **Agents / Bots** (with how many there are), then **Workspaces** — one line per workspace — and
**This Mac**, which holds every page that every workspace shares: **Overview**, **Sessions**, **Sandboxes** (each sandbox
under it), **On this Mac**, **Loose agents**, **Templates** (**Installed**, **Browse**, **Quick try** — its **+** opens Quick
try too), **Images**, **Accounts & keys**, **Resources**, **Devices**, **Logs** (**Operations**, **Activity**,
**Notifications**, **Metrics**), **Doctor**, **Setup**, **Settings** and **Debug**. The **+** beside the **This Mac** heading is
Quick add. The page, sandbox or session you are on is tinted, with a line at its left edge.

A workspace's line in the sidebar shows its state as a dot (a ring while it is setting up), its name, and a caret. Its
name opens the workspace's page (below, [A workspace's page](#a-workspaces-page)); the caret unfolds it into its rooms (**#
review**, each opening that room on the workspace's page) and its agents — a sandbox's opens the sandbox's page, a session on this Mac opens it under **On this Mac**, an
agent elsewhere is its name only. Asleep workspaces fold into one line, **Asleep (2)**, and finished and archived ones into
**Finished & archived (5)**; this browser remembers what you unfolded. Click **Sandboxes** while its page is shown (or
its caret) to fold the list of sandboxes under it, and again to show it; this browser remembers. The
menu button collapses the sidebar to a column of icons (hover one for its name) and expands it again;
this browser remembers. In a window narrower than about 980 px the sidebar is always the column of
icons, and the menu button shows the whole sidebar over the page. On a phone (narrower than about
760 px) the column goes too: a header row across the top holds the menu button, which opens the
sidebar as a drawer, the machine picker, a key button while a key needs you, and **+** for Quick add.

| page | what it's for |
|---|---|
| **Home** | Every workspace, one row each: its state in the words `doz workspace ls` uses (**waiting on you** first, then **working**, **starting**, **idle**, **setting up**, **asleep**; finished and archived fold into one line below), the workspace and its folders, who drives it (**you**), its manager (**mira (fenced)**; an unfenced one says **acts as you** in the warning colour), who is working (for a workspace waiting on you, why — an agent blocked, in error, or a sandbox that failed), its room, the room's last line (while the chat server runs) and one next action: **Sleep**, **Wake**, **Reopen** or **Restore** (the same dialog as on its page) and **Open room** (the workspace's page), or for a workspace still setting up what it lacks and the command that starts it, `doz workspace start NAME`, to copy; asleep workspaces fold into **Asleep (N)** above the finished and archived ones. **New workspace** (also the **+** beside **Workspaces** in the sidebar) opens the New workspace wizard over the page, `#/new-workspace` — the work, who manages it, where it runs and when it starts, with what is still missing shown as you go; only in this Mac's own browser (see [The New workspace wizard](37-workspaces.md#the-new-workspace-wizard)). With no workspace yet, Home says what one is — "A workspace is an environment set up for getting work done: its agents, its rooms, the brief that says what the work is for, and any folders it works on (usually projects). Work starts only once it is fully set up." — offers **Just try an agent** (Quick try), counts the sandboxes and sessions on this Mac that are not in any workspace (**Put them in workspaces…** opens **Loose agents**) and points to **Agents / Bots** for an agent elsewhere. See [Workspaces](37-workspaces.md). |
| **Agents / Bots** | Every Agent / Bot, as `doz bot ls` lists them: its avatar and name, its agent program, how it runs (**acts as you** when unfenced), how the chat server reaches it, the workspaces it manages or works in, who keeps its key, and what it is doing; **Show retired** lists the retired ones. **+ New agent / bot** makes one; a bot's page (`#/bots/NAME`) shows it across its workspaces, its rooms and what it said last, and its tabs edit it; its ⋯ duplicates it, includes it in a room as a voice, gives it a new token or retires it. Only this Mac's own browser changes a bot, and no page ever shows a bot's token — a bot elsewhere gets its token in a terminal. See [Agents / Bots](38-agents-and-bots.md). |
| **This Mac › Overview** | One line for each of This Mac's pages, saying what it holds now: what runs (sandboxes running, sessions on this Mac fenced and unfenced), the loose agents, a key that does not work, the disk Dozable uses (once Resources has measured it), a failed operation, the chat server's state, and the daemon with **Restart daemon** (or **Start daemon**). Nothing is measured or checked when you open it. |
| **This Mac › Your Macs** | The other Macs the machine picker opens, as `doz ui macs ls` lists them: each one's name, address (**plain HTTP** when it is), when it was last seen, what the last check found, **Open**, and the command that removes it, `doz ui macs rm NAME`, to copy; then how to add one, `doz ui macs add NAME ADDRESS`. The list is changed in a terminal on this Mac only. |
| **This Mac › Loose agents** | The sandboxes and sessions on this Mac that are not in any workspace, each with its kind (**micro VM** or **on this Mac**), its state, **Open**, and the command that adopts it, `doz workspace adopt WORKSPACE NAME`, to copy. Nothing moves by itself: adopting changes only the workspace's record. |
| **This Mac › On this Mac** | The sessions on this Mac (`doz run @mac`), fenced or not. Its sidebar line says **N no isolation** while unfenced sessions run. See [Sessions on this Mac](34-sessions-on-this-mac.md). |
| **This Mac › Sandboxes** | Every sandbox: state, RAM held, disk, network, account. Each row has the one likely next action (**Start**, **Resume**, **Wake** or **Pause**) and **⋯** for the state's other actions; click a row to open the sandbox. Under each running or sleeping sandbox, a row of its sessions' pictures (live, or the saved screen), each one opening its session; **Thumbnails under each sandbox** above the table turns these rows off (this browser remembers): the pictures are then small, in a **Sessions** column — a grid in a 4:3 box, smaller the more sessions there are. Rest on any picture for half a second to see it larger. Every picture of a running sandbox is live: it follows its session within about a second while it is on screen (pictures you have scrolled past are not asked for, and keep their last screen until you scroll back). A picture marked **last screen** is one the daemon could not give live (a session started before an update of Dozable, for instance): it shows the session's last saved screen instead. Tick sandboxes in the left margin and the controls above the table — **Start** (start, resume or wake), **Pause**, **Sleep**, **Hibernate**, **Shut down** (asks first) — act on those; with none ticked they act on every sandbox, and each says how many it applies to. They do not all run at once — every start or wake would be slower: at most `ui.batch_concurrency` (3) starts, wakes, resumes, sleeps, hibernations and shut-downs run at a time, and the others wait their turn, each row saying **queued — 2 ahead** (or **queued — next**) with a small **Cancel**, and the controls **N queued · Cancel all**. A cancelled one did nothing. One you start yourself on a single sandbox, or by typing in its terminal, goes ahead of them; a pause, and a resume from a pause, never wait. **Quick add** (every default, started and opened — also the **+** beside the **This Mac** heading in the sidebar; see [The quickest way](05-sandboxes-and-lifecycle.md#the-quickest-way-quick-add-and-doz-new)) and **New sandbox** (a wizard: every choice, step by step, written to the project folder's `doz_project.yaml` — see [Projects](04-projects.md#in-the-dashboard)). Under it in the sidebar, each sandbox has its own entry that opens **its page** at its Home; its dot is filled while the sandbox holds memory (running, paused, asleep), a crescent moon when it is hibernated, a ring when it is shut down, a square when it failed; a second dot at the right says what its agent is doing (see [What the agent is doing](07-terminals-and-sessions.md#what-the-agent-is-doing)). Under each sandbox, all its **sessions** (each with its agent's mark, or a terminal for a shell), in the order of the tabs on its page (then any without a tab: the agent's first), each with what it is doing; click one — or its screen icon — to open it; **⋮** (on hover) has **Restart session** and **End session**, and the screen icon beside it shows the session's live picture when you rest on it for half a second (then another session's line shows its picture at once). A sleeping sandbox lists the sessions it wakes back into. The caret beside a sandbox (or a click on the sandbox while its Home is shown) folds it to one line with its number of sessions (a session that needs you or failed still shows); this browser remembers the fold. **⋮** on the **Sandboxes** line (on hover) has **Expand all** and **Collapse all**. |
| **A sandbox's page** | See [A sandbox's page](#a-sandboxs-page) below. |
| **Chat** | Shown while chat is on (`doz chat on`): the rooms you share with your agents, a room's messages as they come, who is here, and a composer. React, edit your own messages (the pencil, or **Up** in an empty composer), delete any message (with a box to tick), reveal a direct message between agents, and attach files by the clip, a paste or a drop (at most 20 MB each). A badge counts what is unread in other rooms. While chat is off, **Turn chat on** here (this Mac's own browser) does what `doz chat on` does; turning it off is a terminal's. See [Chat](36-chat.md). |
| **This Mac › Sessions** | A grid of live, read-only tiles: every session of every running sandbox, each with what its agent is doing. Click a tile to open it. Every tile is live while it is on screen, however many there are; a sleeping sandbox's tiles show its saved screens, and a tile marked **last screen** shows its session's last saved screen because the daemon could not give the live one. Rest on a tile's picture for half a second to see it larger; **Larger on hover** turns that off (this browser remembers). |
| **This Mac › Templates › Installed** | The recipes in use (a sandbox runs the agent) and installed (a baked image of it is here), each with its sandboxes, baked images and the values you set. A recipe's page has its settings (each with where its value came from), its baked images, its sandboxes and **Uninstall**. |
| **This Mac › Templates › Browse** | Every recipe in the catalogue, with a search (a name, a vendor, what it is); one on this Mac says **in use** or **installed**. Open one for its page. |
| **This Mac › Images** | The images and templates, each image's agent version, what's out of date (**Rebuild** — **Remove…** is under **⋯**), disk shared and own, and the **Lineage** tree. |
| **This Mac › Resources** | Every byte Dozable uses, and deleting what can go. A strip under the total jumps to each group (with its size); a group's heading folds it. See [Resources and disk space](13-resources-and-disk-space.md). |
| **This Mac › Logs › Operations** | Every action the dashboard (or a preparation) started: live progress, time taken, result. A spinner shows while any runs, and a red dot when one failed since you last looked. One still waiting its turn shows an hourglass and **queued — N ahead**, with **Cancel** (and **Cancel N queued** above the list); its time starts when its turn comes. |
| **This Mac › Accounts & keys** | The keys and sign-ins your sandboxes' tools use: **Needs you** (what is broken and the one fix), the **Keys** view (each provider's keys, its default, check, remove), the **Sandboxes** view (the key each sandbox uses — change it in place), **Add a key** (start from the tool). A red count beside it in the sidebar while a key a sandbox relies on does not work. See [Accounts — in the dashboard](09-agents-and-accounts.md#accounts--in-the-dashboard). |
| **This Mac › Logs › Metrics** | How long each kind of action takes (count, median, p90…), filtered by image and time; download as CSV. |
| **This Mac › Logs › Activity** | What the daemon is doing, live. |
| **This Mac › Setup** | The setup wizard, again (in a window over the page, as **New sandbox** is). |
| **This Mac › Doctor** | `doz doctor`'s checks, with **Run onboarding again**. |
| **This Mac › Settings** | Laid out like VS Code's settings: the search across the top, then every setting as a block — its name (with its key, `ui.theme`), its description, and the control under them (a checkbox before the description for an on/off one) — with where its value came from (a badge: recipe · default · Mac · project · sandbox · env · flag); change it in place. A value set on this Mac, by the environment or by a flag has a bar at its left; **Default** puts this Mac's back. A recipe's own settings are on its page under **Templates**. The search finds a setting by its key, its name, its section or a word of its description, across every section. When the page is wide enough, the sections are listed on the left (Access first), the one you are reading marked; a click jumps to it — narrower, the list is not shown. Folders on your Mac are never typed here: the projects folder has **Choose…**, your Mac's own folder picker; the others are set with `doz config set`. A new sandbox's permissions (`defaults.permissions`) are a table of what **Locked**, **Standard** and **Open** each allow, the current one marked, with the choice under it; **Custom** shows a switch for each permission. A sandbox's own values are on its page, **Config › Settings** (what it overrides, with **Follow the Mac**). |

### Your other Macs (the machine picker)

"**Dozable · studio ▾**" at the top of the sidebar — this Mac's name — is a button: it opens **Your Macs**. This Mac comes
first (**you are here**), then each Mac you added with `doz ui macs add NAME ADDRESS` (its Tailscale name or LAN address —
see [Adding this Mac to another's list](25-doz-serve.md#adding-this-mac-to-another-macs-list)), then **Add a Mac…** and
**Manage…**, which open **This Mac › Your Macs**. Each Mac shows a dot, its name, its address, **plain HTTP** when it is
not https, and what the last check found: a filled dot and **seen 3 min ago** when a check in the last ten minutes found
it, else a hollow dot and **last seen 2 days ago** or **never checked**; one that could not be reached says why, and the
command that checks it again (`doz ui macs check NAME`). Picking one opens that Mac's own dashboard in a new tab — the
same as typing its address: you sign in to it there with `doz ui share` on that Mac. Nothing of this Mac's goes with
it: no key, cookie or sign-in link is ever passed, kept or shown, and this page never contacts the other Mac (whether it
answers is checked only by `doz ui macs add` and `doz ui macs check`). Each Mac stays its own: its own daemon,
workspaces, agents and keys. On a phone, the name in the header row opens the same list. **Enter**, **Space** or
**↓** on the name opens it, the arrow keys move through it, **Escape** closes it; **g** then **m** opens it from anywhere.

### A workspace's page

A workspace's page (`#/w/NAME`; the sidebar's name, Home's row and **Open room** lead there) puts its room first. The
title row has its name, its state, who drives it, its manager (an unfenced one says **acts as you**), one button for what
its state offers next — **Start** while it is setting up, **Sleep** while it runs, **Wake** when it is asleep, **Reopen**
when it is finished, **Restore** when it is archived — and **⋯**: **Stop the manager**, **Sleep everything**, **Wake
everything**, **Finish…**, **Archive…** and **Delete…**, and what it still lacks. Each opens a dialog that shows what it
would do to each agent (on a phone, a card each), what is kept and what goes with sizes, how many change at once and
**Show the command**; finish asks once, archive and delete want the workspace's name typed, and **Also free …: remove the
sandboxes Dozable made for it** and **Also move its folders on this Mac to the Bin** are never ticked for you. While it
works the state reads **sleeping…** or **waking…**. Only this Mac's own browser does these (see [Workspaces](37-workspaces.md#sleep-wake-finish-archive-and-delete)). Below are its tabs: **Room**, **Agents**, **Network & secrets**,
**Folders & points** and **Activity** work; **Permissions** and **Settings** are marked **coming** and say what they will hold.

**Network & secrets** answers "what can this workspace reach?": each agent's network and the sites beyond it, what it was
refused lately — **Allow for** that agent, or **For all** that can be limited (an unfenced agent and one elsewhere cannot; the
default for new workers does not change) —, this Mac's ports and the forwarded ones, the secrets held for its agents by name,
where each goes and a fingerprint, and the accounts used. Nothing on it is a secret's value. Allowing a site for a session on
this Mac is done only in this Mac's own browser. **Folders & points** lists each folder, the files changed in it since the
work started (found without running anything there; it never says which agent changed a file) and each micro VM agent's
restore points, with **Take a restore point**. **Activity** is the workspace's log, newest first (**Load older** for more),
with the operations this dashboard started for its agents (the last 50); show **All**, **You**, **Agents**, **Lifecycle** or
**Network**. Each tab is read afresh when you open it. An agent's **Can do** (the **Can do** button on its screen) is its
capability table: each row live or at the next start, an unfenced agent's **acts as you**, and last its **Permissions**
(how many allow, ask and never — the counts `doz permissions show W --agent A` prints) and its **Ceiling**, read only.

**The work** — the brief — sits above the room: its text, its references (a link opens in a new tab), who wrote it and
when, and how many times it was edited. It is open on the workspace's page and one line on another room's; **Fold** and
**Open** change that, and this browser remembers it for each workspace. **Edit** changes the brief and nothing else; once
the work has started, saving posts it in the room as your message ("I edited the work:" and the new text). If the brief
changed since you opened it (from a terminal, or another browser), the save is refused and nothing is written. A brief
over about 15 KB is saved with `doz workspace edit NAME --prompt-file FILE` instead (the page shows the command).
**History** lists the edits — when and how long — each after the start linking to its message in the room.

The room is the same as on the Chat page — its messages, the composer, reactions, edits, attachments — showing only this
workspace's rooms (a strip of **# label**s; **+ room** is not there yet). Each agent's name carries its place in the
workspace — its role, its agent program, how it is isolated, its session (`manager · Claude Code · fenced`) — and an
unfenced one **acts as you**. What `doz workspace log` says (the work started, the brief edited, a worker added) shows
among the messages in grey, by time; it is never posted in the room. An address naming a room that is not this
workspace's opens its main room and says so.

The side panel says who is here and in what: each agent with its state, its isolation (**micro VM**, **fenced**,
**unfenced**, **elsewhere**), a worker's task — each opens its screen in the workspace (below) — then **In this room**,
the workspace's folders and its network. **+ Worker** opens **Add a worker** (below). In a narrow window the panel is
below the room. Every isolation chip — here, on the Agents tab, on an agent's screen and in Agents / Bots — opens **the
isolation guide** (`#/guide/isolation`) at that choice: micro VM, fenced on this Mac, unfenced on this Mac and elsewhere,
in order of isolation, each with what it is for and not for and its commands.

**Agents** (`#/w/NAME/agents`) is one table of every agent of the workspace, whatever runs it: where it is (**this Mac** or
**elsewhere**) and how it is isolated (**micro VM**, **fenced**, **unfenced** — which says **acts as you** and "no proxy · no
placeholders · no guard" — or **elsewhere**, "not run by Dozable · token only"), its state, its task, what it uses and what
isolates it, who started it and when, **Watch** (or **Open**) and **⋯** (its screen, Open in Terminal, Restart, **End…** for a
worker — ticked, its place kept —, **Take out of the workspace…** and **Move to another workspace…**). **+ Add a worker** opens
**Add a worker** (`#/w/NAME/agents/new`): the agent program, its name, the account it would use (shown, not chosen), its one
task, its rooms, who it is (anonymous, or an Agent / Bot), where it is, and **where it runs** — a table of micro VM, fenced,
unfenced and cloud (later) side by side, fenced chosen unless the workspace's or the bot's default is micro VM; unfenced is
never chosen for you and needs the tick "It acts as you". Each field is checked as you type and a refusal shows beside it;
**Show the command** gives `doz worker add …` to run in a terminal instead; **Add and start** adds it. A worker that ended is listed folded
below; a greyed "cloud worker" row shows where a worker run off your Mac will appear later; **Grid** is coming. In a narrow
window each agent is a card.

**An agent's screen** (`#/w/NAME/agent/AGENT`) is its sandbox's page, or its session's on this Mac, as you know them — the
terminals, Home, the details — under the workspace's name: a line `NAME › Agents › AGENT` with its chips and **Open the
room beside** and **⋯** (Add a worker…, and End… for a worker), and in the details' Overview **In this workspace** (its
role, task, who started it and when, its isolation and rooms). Switching its tabs keeps that address. An agent with no screen here — one elsewhere, a manager not started, a
sandbox or session that is gone — shows a card saying so (and, for one gone, **Take out…**). A sandbox's own page
(`#/sandbox/NAME`) still opens as itself; for one in a workspace it says **In NAME as AGENT — open it there**.

### Old addresses

The dashboard's addresses moved with its pages; a bookmark or a link to an old one opens the page's new address (the
address bar shows the new one):

| old address | opens now |
|---|---|
| `#/` (or none), `#/overview` | `#/home` (Home), `#/mac/sandboxes` (This Mac › Sandboxes) |
| `#/sessions` | `#/mac/sessions` |
| `#/mac/SESSION` | `#/mac/here/SESSION` (On this Mac) |
| `#/recipes`, `#/recipes/VENDOR/PRODUCT`, `#/browse` | `#/mac/templates`, `#/mac/templates/VENDOR/PRODUCT`, `#/mac/templates/browse` |
| `#/images`, `#/resources`, `#/accounts`, `#/devices`, `#/doctor`, `#/settings`, `#/debug` | `#/mac/images` and so on |
| `#/operations`, `#/activity`, `#/notifications`, `#/metrics` | `#/mac/logs/operations` and so on |

`#/sandbox/NAME`, `#/chat`, `#/new` (New sandbox), `#/onboarding` and `#/try` are unchanged; `#/new-workspace` is the New
workspace wizard (`#/new-workspace?bot=NAME` with that Agent / Bot chosen as its manager). A workspace's page is `#/w/NAME` (its main
room) and `#/w/NAME/room/LABEL` (another of its rooms, by its short label); its Agents tab is `#/w/NAME/agents` and an
agent's screen `#/w/NAME/agent/AGENT` (with `/SESSION` for one of its sandbox's sessions). `#/mac` alone is now This Mac's overview
(its first line leads to On this Mac), and a session on this Mac named like one of This Mac's pages (`images`, `logs`, …)
is reached from On this Mac rather than by its old address.

### A sandbox's page

![A sandbox's page](images/sandbox-page.png)

- **The title row**: the name, its state, and labelled facts — **Image**, **RAM**, **Network** (with
  how many connections were refused; click it for the **Network** tab), **Account** — and *isolated*
  or *rules* when they apply.
- **The toolbar**: the state's actions as one group — led, for a sandbox that is shut down, paused,
  asleep or hibernated, by the action that brings it back (**Start**, **Resume**, **Wake**); **Shut
  down** apart, in red; **⋯** for **Duplicate…**, **Save as template…**, **Boot log**, then **Reset…**
  and **Remove…**. At its right: what is under way (or how the last action ended), and the button that
  shows or hides the details.
- **The terminals**, whose tab strip carries what makes or arranges them: **New Claude Code session**
  (another session of the sandbox's own agent — `claude-2`, … — when it runs one), **New shell** (its **▾**:
  **Terminal…**, **Run detached…**), **Split** (its **▾** picks what a split adds) and **Open in
  Terminal**. At the strip's left, the **tabs menu** (**▾**) lists every tab open here, with **Close all
  tabs** (the sessions keep running) and **End all sessions…**. The first tab is **Home** (below); then
  **Console** (the kernel and the guest's init, while the sandbox runs) and the sessions' tabs; the image's
  **Build log** opens in a tab of its own from Home › Logs. **Start** on the
  page opens the agent too; a start from a row of **Sandboxes** only boots it — its **Home** then
  offers **Start Claude Code** (or the sandbox's agent).
- **Home** — every session of the sandbox, in one place: the agent's session as a card (what it is
  doing, since when, which tab shows it, **Open**, **End…**, and **⋯** for **Watch**, **Open in
  Terminal**, **Restart session**), the other sessions as rows, each with a small picture of its
  screen (live while the sandbox runs and Home is shown — a session with a tab mirrors that tab, every
  one of them, however many; its saved screen while it sleeps), then
  **Logs** (**Console**, the build log, the boot logs) and the **Folder**. **List | Grid** shows the
  sessions as a list or as a grid of their live pictures. The tab shows how many sessions run. **A
  running session's ✕ asks**: **End session** (its program stops), **Hide — keep running** (the tab
  goes, the session goes on) or **Cancel**; a read-only view, a saved screen or a second tab on the same
  session just closes. Closing the agent's tab another way (the tabs menu's **Close all tabs**) brings
  you back to Home, which says the agent is still running — every time, until you click
  **Don't say this again** (the setting `ui.explain_tab_close`). **Console** can be closed at any time,
  even during a boot; it stays closed until the next **Start** (Home › Logs › **Console** opens it again).
- **The details**, beside them in tabs: **Overview** (RAM, disk, CPUs, the attach command, the
  folder and its rules, its sessions and last restore point), **Points** (restore
  points), **Network** (**What the agent can do**, the rules, the connection log), **Keys** (keys and
  account) and **Config** (its configuration and the agent's environment prompt). The tab you chose is
  kept for each sandbox while the page is open; drag the details' left edge to widen them (320–560 px).
  Below about 760 px they move under the terminals.

### Safety catches

**Reset**, **Remove**, **Revert** and every delete ask you to tick a box first ("Yes, remove …"). **Shut down**
asks with a plain confirmation. Clicking an action again while it runs does nothing more.

### When something fails

A failure is said where you started it, and stays until you dismiss it or it is put right: in the
dialog (which stays open), on the sandbox's toolbar or its row on **Sandboxes**, in the step of a
wizard, in the setting's row — or, when it has no place on the page you are on, at the top of the page.
The brief messages at the bottom right only ever say that something worked. **Operations** keeps
every action's result either way.

### Keyboard

Every control shows a ring when it has the keyboard's focus. Arrow keys move within tabs, segmented
choices and menus; **Escape** closes a menu or a dialog. Five page shortcuts: **g** then **h** opens
**Home**, **g** then **s** opens **This Mac › Sandboxes**, **g** then **m** opens Your Macs (the machine picker), **/** the
Settings filter, **?** the list of shortcuts. None of them works while a
terminal has the focus — there every key is the terminal's.

### A workspace's runs

A workspace's **Runs** tab lists each run — each start or reopen to its finish — with its length, whether its archive was
written and how big it is, and its totals. **Read its messages** opens a past run's chat from its archive, read-only, with
its timesheet. Below, each of the workspace's rooms shows its state (open, closed, archived or gone). In this Mac's own
browser, **Archive room…** and **Remove room…** put a finished workspace's room away and then remove it for good; Remove
room… asks you to type the room's name. When a workspace is finished, its room's message box is off and says so; reopen
the workspace to post again. The Finish dialog shows what becomes of each room and what the run's archive will hold, with
**Finish without an archive** unticked.

## The daemon, watched

The status bar at the foot of the sidebar (it stays there as the sidebar's pages scroll; the sidebar's head stays at its top) starts with a dot for the dashboard's connection and
one for the daemon, then the version, or what is wrong. Point at it for its card; click (or tap) it to keep the card open. The card
has:

- **doz ui** — the dashboard's connection.
- **daemon** — whether the daemon runs, and its version, with **Restart** (it asks first, hibernates what
  runs — sessions kept, they wake when you use them — and starts the daemon again, as
  `doz daemon restart` does) or **Start** while none runs.
- A line when the daemon and the dashboard are **different versions**, or a newer doz is installed than the
  dashboard runs, saying which is older: an older daemon is fixed by **Restart**; an older dashboard by
  **Restart dashboard** (in this Mac's own browser — another computer's page does not offer it) or `doz ui restart`.
  The page waits for the dashboard to come back and reloads itself.
- **updates** — what the last check found (a newer doz and the command that installs it, or up to
  date, and when it was checked), with **Check** to look now. A doz built from source is never updated,
  and says so.

Notifications tell you what happened to the daemon:

- **The daemon stopped** (`doz daemon stop`, idle, or a clean quit): your sandboxes were hibernated, with
  **Start daemon**.
- **The daemon crashed or was killed:** the sandboxes that were running (they are shut down; start them
  again).
- **Another version of the daemon took over:** it says so. If the daemon is **older** than the dashboard,
  **Restart daemon** asks first, hibernates what runs and starts the newer daemon (sandboxes wake when you
  use them). If the dashboard is the older one, **Restart dashboard** (or `doz ui restart`).

## Notifications

Everything the dashboard tells you appears in the top right corner: a success (it goes by
itself after a few seconds), a failure or a warning that has no closer place (it stays until you close
it, or until it is no longer true), and the news about the daemon and the dashboard itself. The setting
`ui.notifications` (**Settings › This UI**) chooses how they look:

- **Cards** (the default) — a bell in the corner with the count, and a column hanging below it, the
  newest on top, each with its full text and buttons. A success has a strip along its foot counting
  down the seconds it has left. Point at any card and every countdown waits, and the column turns
  solid with **Dismiss all**; move away and they go on from where they were. Click the bell to hide
  the cards, and again to show them; a new notification shows them again. With none showing, the
  bell opens an empty column with the **History** link.
- **Pills** — one line each along the top, the newest at the right; the ones that don't fit fold into
  **+N**. Click a pill for its full text and buttons.
- **Bell** — a count; the newest shows beside it for a few seconds. Click the bell for the list, with
  **Clear all**.

**Notifications** (in the sidebar, under Activity) is the history: every notification this tab has
shown, newest first, with the time — the ones showing now with **Dismiss**, and for the others how they
ended (dismissed, went by itself, no longer true). Filter it by Showing, Failures, Warnings or
Successes; **Clear history** forgets the ended ones. It lasts until the tab is closed.

The **Debug** page (in the sidebar, under Setup) makes each kind of notification with sample words, so
you can see how each looks in each style. Nothing on it asks the daemon or changes a sandbox.

## When `doz ui` restarts or stops

A restart is routine — an upgrade, `doz ui restart`, the Mac waking up. For the first seconds the page
says, calmly, **Reconnecting to Dozable…**; nothing behind it can be clicked meanwhile. When `doz ui`
answers again the page carries on where it was, still signed in, with no reload:

- **Terminals reattach by themselves**, with their screens (what you typed while it was away is
  dropped, never typed later). An open **New sandbox** wizard keeps its choices.
- **An operation that was running** (a start, a wake) ends with what happened — the daemon carried it
  on — "finished while doz ui restarted", never a spinner that never stops.
- **A newer doz ui** (after `brew upgrade doz` and a restart): a notification says *Dozable was updated* with
  **Reload**; the page reloads by itself as soon as nothing would be lost (no wizard or dialog open, no
  terminal you're typing in, nothing typed in a field).

If `doz ui` was stopped (Ctrl-C), or doesn't come back within 15 seconds, the overlay says what to run,
when it was last connected and whether the daemon was running, with **Try now**; after a minute it adds
the port the page expected. The page retries every second and comes back by itself when you start
`doz ui` again (it says "doz ui restarted").

![Paused while doz ui is away](images/dashboard-overlay.png)

**When the page must sign in again** — after `doz ui --new-link` / `doz ui link --rotate`, after 14 days
unused, or when you signed out — it says why and asks for a link **inside the page**: paste one from
`doz ui link --print-url` (or open one with `doz ui link`). Everything on the page stays as it was while
you sign in; its terminals reattach afterwards.

## Terminals in the browser

On a sandbox's page, a session's **Open** (on its **Home**) attaches to it and **Watch** (its **⋯**) shows it read-only; on the terminals' tab strip **New shell**
starts a new shell (`shell-2`, `shell-3`, …) and its **▾** › **Terminal…** starts a new session — a shell
or one running a command. Terminals are tabs; **Split** shows two side by side. A running session's ✕
asks whether to **End** it or **Hide** its tab and keep it running. Each tab is titled like `1 · my-app · claude · 14:05` (the setting
`ui.terminal_title`). Details, including the mouse, paste and the clipboard, in
[Terminals and sessions](07-terminals-and-sessions.md#in-the-browser).

**Open in Terminal** opens the same session in your terminal app instead, via `doz attach`.

**Open folder** (the folder icon beside it) opens the sandbox's shared folder on your Mac — **Show in the
Finder**, or **Open in &lt;editor&gt;** for each editor installed (VS Code, Cursor, Zed, …; the one you used last
first). An isolated sandbox has nothing on the Mac: the button says so. The same as `doz files open NAME --app
EDITOR` ([Terminals and sessions](07-terminals-and-sessions.md)).

## Keys in the browser

With `ui.allow_secret_entry` on (the default), the wizard and **Accounts & keys** take an API key or
setup token in a masked field, sent once and stored exactly as `doz account add` stores it. A
sandbox's page can take a key of its own the same way. The dashboard never shows a secret: accounts
and keys appear as a state, a source and a fingerprint. Turn it off with
`doz config set ui.allow_secret_entry false` — the pages then show the commands instead. The
dashboard can switch this off but never on.

## Settings

| key | default | what it does |
|---|---|---|
| `ui.open_browser` | `auto` | When `doz ui` opens a tab: `auto` (only when no page is open), `always`, `never`. |
| `ui.port` | `0` | The port on 127.0.0.1: `0` = the last one when free, or a fixed port 1024–65535 (for an installed app). |
| `ui.theme` | `auto` | `auto` follows macOS; `light`; `dark`. The sun / moon at the right of the status bar, at the foot of the sidebar, sets it. |
| `ui.density` | `comfortable` | `compact`: tighter rows, tabs, controls and page margins — the text stays the same size. **Settings › This UI** switches it at once. |
| `ui.notifications` | `cards` | How notifications look in the top right corner: `cards`, `pills` or `bell` (see [Notifications](#notifications)). **Settings › This UI** and the Debug page switch it at once. |
| `ui.nav_thumbnails` | `true` | A session line in the sidebar shows a screen icon on hover; resting on it for half a second shows the session's live picture. |
| `ui.terminals` | `true` | Terminals in the browser. `false`: none open (Open in Terminal still works). |
| `ui.terminal_font_size` | `13` | Font size of a browser terminal (9–32). |
| `ui.terminal_title` | `{sandbox} · {session} · {time}` | A terminal tab's title (and your terminal's, in `doz attach`). |
| `ui.split_default` | `shell` | What **Split** opens: `shell`, `watch`, `attach` or `dialog`. |
| `ui.details_open` | `true` | A sandbox's page shows its details (the tabs beside its terminals). |
| `ui.boot_view_on_start` | `false` | After **Start**, stay on the **Console** tab rather than switch to the agent's tab. |
| `ui.explain_tab_close` | `true` | Closing the agent's tab: **Home** says it is still running (until **Don't say this again**). |
| `ui.confirm_shutdown` | `true` | **Shut down** asks first. |
| `ui.grid_live_tiles` | `12` | No longer used — every picture is live; kept so an older settings file still reads. |
| `ui.grid_tile_size` | `medium` | All sessions: `small`, `medium`, `large`. |
| `ui.grid_refresh_ms` | `500` | How often the pictures are brought up to date, in milliseconds (200–10000). |
| `ui.batch_concurrency` | `3` | How many starts, wakes, resumes, sleeps, hibernations and shut-downs run at once (1–8); the others wait their turn, queued, with a **Cancel**. Applies as soon as one ends. |
| `ui.progress` | `animated` | How starts and preparations show their progress: `animated` or `plain`. |
| `ui.allow_secret_entry` | `true` | The dashboard may take a key or token (see above). |

## Limits and security

- **Loopback only** unless you turn on its LAN option, and every page, request and terminal checks the sign-in
  cookie, the exact host and origin, and a CSRF token on every change. For the same dashboard on your other
  computers, tablets and phones, see [`doz ui --lan`](25-doz-serve.md).
- **Terminals run in an isolated frame**: whatever a sandbox prints can never reach your dashboard
  session, its cookie or other terminals. Links in terminal output aren't clickable.
- The dashboard alone never keeps an idle daemon running; an open terminal does, as `doz attach` does.

## Troubleshooting

| symptom | what to do |
|---|---|
| "Sign in with a new link" | The link was used, expired, or every page was signed out: paste a link from `doz ui link --print-url`, or open one with `doz ui link`. |
| A terminal says "Disconnected" | It was silent a long time, or it could not reattach: **Reconnect**. (After a restart or a sign-in it reattaches by itself.) |
| "Dozable moved to 127.0.0.1:…" | `ui.port` changed and `doz ui` restarted there: use the tab it opened (an installed app: install it again from there). |
| The installed app shows "Dozable isn't running" | Start `doz ui`; the window comes back by itself. |
| "ui.port is …, and … listens on 127.0.0.1:…" | Another program holds the fixed port: stop it, or `doz config set ui.port N` (`0` = automatic). |
| Two tabs open each time | Set `ui.open_browser` to `auto` (the default) or run `doz ui --no-open`. |
| Open in Terminal does nothing | Make a terminal app the handler for `.command` files: Finder › Get Info on any `.command` file › Open with › Change All… |
| "the resources are missing" | Reinstall: `brew reinstall doz`. |
