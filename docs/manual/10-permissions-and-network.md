# What the agent can do: permissions and the network

A sandbox has **no network card**. Its only way out is a proxy in Dozable's host, on your Mac, which
checks every connection against the sandbox's **permissions** — a short list of plain-language
switches — and logs it. You decide what the agent may reach; the agent can't change it.

## Concepts

- **Permissions** are what an agent may do, each a switch:

  | permission | id | what it allows | in Standard |
  |---|---|---|---|
  | Talk to its AI model | `model` | Anthropic's API | always on |
  | Talk to OpenAI | `model:openai` | Codex's model (`chatgpt.com`, `api.openai.com`) — [Codex](24-codex.md) | always on in a Codex sandbox; never in another agent's |
  | Sign in | `sign-in` | Claude's sign-in pages, for signing in *inside* the sandbox | off (Dozable supplies the credential) |
  | Update itself | `update` | new versions of Claude Code or pi | on |
  | Install software — system packages | `install:system` | apt / apk | on |
  | Install software — Node, Python, Go, Rust, Java, Ruby, .NET | `install:node`, `install:python`, `install:go`, `install:rust`, `install:java`, `install:ruby`, `install:dotnet` (`install` = all) | that language's package registry | your base's language |
  | Install software — Swift | `install:swift` | Swift packages (the Swift download site, the Swift Package Index) | on for a fenced session on this Mac |
  | Use GitHub | `github` | clone and fetch code, Git LFS files; Claude Code's plugins | on |
  | Use GitHub as you | `github:as-you` | git and gh signed in as you — read-only ([GitHub as you](18-github.md)) | off, in every preset |
  | Push to GitHub | `github:push` | also push and change things on GitHub as you | off, in every preset |
  | Send error reports | `error-reports` | the agent reporting its own crashes to its maker | on |
  | Browse the web | `web` | any website | off — **the agent could send your code anywhere** |
  | Sites you allow | `site:HOST`, `site:HOST:PORT`, `site:HOST:PORT,PORT` | one host — a name (`api.example.com`), a wildcard (`*.example.com`) or an IPv4 address — on every port, or only on the ports you name | none |

  `doz net permissions` lists every permission with the exact hosts behind it in your version of Dozable.
- **Presets:** **Locked** (its AI model only), **Standard**, **Open** (everything, still logged). Your
  GitHub login is never part of a preset — not even Open: it's switched on by name, and a preset you
  choose later keeps it as it was.
  New sandboxes get the setting `defaults.permissions` (`standard`).
- **Stored by name.** A sandbox remembers "Update itself", not a list of hosts, so when a new version
  of Dozable adds a host to a permission, every sandbox that has it gets it.
- **Live.** A change applies to the sandbox's next connection — no restart — and is kept for its
  next start.
- **Everything is logged:** host, verdict, rule, bytes. Never the contents.

## The default

Every new sandbox — `doz new`, `doz try`, Quick try and the setup's First sandbox alike — starts on **Standard**
(`defaults.permissions`). It's the balance most agent work needs: the agent can talk to its model, update itself,
install software (apt, npm, PyPI and its base's other package managers) and use GitHub, so `sudo apt-get install` and
`npm install` just work. It cannot browse the web at large, so it can't send your code to a site you never allowed.
Every refusal is on record, and the sandbox's **Network** tab offers to allow it.

**Locked** (its model only) is one choice away — `--network locked`, or the Network tab — for an agent you don't trust
with anything else; **Open** is for when you decide the web is fine. A sandbox runs on your Mac with your project
folder in it, which is why the default isn't Open.

## See what the agent can do

```sh
doz net my-app            # the checklist, its sites, and what it was refused lately
doz net log my-app        # the connection log
doz net log my-app --denied --follow
```

When the agent was refused something a permission would allow, `doz net` says so — "the agent tried
to install Python packages (PyPI), 3 times" — with the command that allows it.

## Change it — in the terminal

```sh
doz net allow my-app install:python          # switch a permission on
doz net allow my-app site:api.example.com    # one site (every port)
doz net allow my-app site:100.64.0.5:8780    # one site, one port (site:HOST:80,443 for several)
doz net deny my-app github                   # switch one off
doz net deny my-app site:tracker.example.com
doz net deny my-app site:100.64.0.5:8765    # just that port, under a site you allowed whole
doz net allow my-app locked                  # or standard, open: a preset
doz net allow my-app web --yes               # asks first without --yes
doz create my-app --allow install:rust,site:api.example.com,-error-reports
```

`--allow` on `create` and `up` adds to the default: permission ids, `-PERMISSION` to remove one,
`site:HOST` or `site:HOST:PORT[,PORT]`, or a preset name.

A site with no port is every port of that host, as it always was; with ports it is only those. **A deny beats an
allow for the same host** — a whole-host deny blocks every port, and a deny of one port blocks just that port even
where the whole host is allowed. Allowing a port of a host you had denied whole lifts that deny (the command says
"lifted: deny HOST"). An address of this Mac itself, its loopback and link-local addresses and cloud metadata stay
refused whatever a site rule says. A refused connection to a port other than 80 or 443 is offered as that host and
port (`site:HOST:PORT`), not the whole host.

## This Mac's ports

Your Mac's own addresses are never reachable from a sandbox or a fenced session — with one deliberate exception: a
port of your Mac you open to it. It then reaches the service there (a message server, a dev server, a local API) by name, as
`host.dozable.internal:PORT`, and nothing else of your Mac:

```sh
doz create my-app --host-port 8780            # at creation (repeatable); doz_project.yaml: host_ports: [8780]
doz run my-app --host-port 8780 -- bash       # a sandbox keeps it
doz run @mac --host-port 8780 -- claude       # a fenced session on this Mac
doz net allow my-app host:8780                # live, while it runs
doz net deny my-app host:8780                 # closed again, live
```

- **Only that port, only by that name.** The proxy sends `host.dozable.internal:8780` to `127.0.0.1:8780` on your
  Mac. Any other port of the name is refused with the ports that are open. `127.0.0.1:8780`, `localhost:8780` or your
  Mac's Wi-Fi or Tailscale address with the same port stay refused — only the name is the way in.
  `mac.dozable.internal` is the same route (its older name, from [Claude Code and other models](32-claude-code-other-models.md)),
  and a model server's port is one entry of the same list.
- **Never a permission.** `host:PORT` is not a site and not part of any preset — **Open opens the internet, not your
  Mac**. `--permissions host:8780` (and `--allow`) is the same as `--host-port 8780`.
- **Never Dozable's own ports** (the dashboard's, a fenced session's proxy, a sandbox's forwarded web port), port 0
  or a port below 1024 — refused when asked, and again at each connection (a dashboard may start later on that port).
- **Plain HTTP** to it works as to any site; a credential placeholder is never sent there — but for a secret you give
  for that very port ([A secret for a service](#a-secret-for-a-service)).
- `doz net NAME` shows them ("This Mac's ports: 8780 (named), 11434 (model server)"), as does the dashboard's
  Network tab (read-only there: change them with `doz net allow|deny`). A refused connection to the name suggests
  `host:PORT`. The model server's port belongs to its model source: `doz net deny NAME host:PORT` does not take it away.
- **Live changes** follow the setting `network.host_ports_live` (on by default). Off, `doz net allow NAME host:PORT`
  is refused — the ports are fixed when the sandbox or session starts (`--host-port`); `doz net deny` always works.

**Which session is asking.** `--host-port 8780:tag` (or `host:8780:tag`) makes every plain-HTTP request through the
route carry `X-Dozable-Session` naming its sender — the sandbox's name, or `@mac/SESSION` for a fenced session; any
copy the program sent itself is removed first. It is identification, not authentication: any program on your Mac can
send the same header to the service directly. A request inside a tunnel (`CONNECT`, HTTPS) is not read by the proxy,
so it carries nothing added. Without `:tag` the route passes the program's own fields untouched.

## A secret for a service

A service your agent talks to — a message server on your Mac, an API on your Tailscale network — may want a token.
`--secret` gives it one without the token ever entering the sandbox or the fenced session: Dozable reads it from a file,
keeps it, and the session sees only a placeholder that Dozable's proxy swaps for the real token on requests to exactly
one host and port.

```sh
doz create my-app --host-port 8780 \
    --secret SERVER_TOKEN,src=~/.config/token,to=host.dozable.internal:8780,file=SERVER_TOKEN_FILE
doz run my-app --secret SERVER_TOKEN,src=~/.config/token,to=host.dozable.internal:8780 -- bash
doz run @mac --host-port 8780 --secret SERVER_TOKEN,src=~/.config/token,to=host.dozable.internal:8780 -- claude
```

Inside, `$SERVER_TOKEN` holds a placeholder (`doz_cred_…`); with `file=SERVER_TOKEN_FILE`, `$SERVER_TOKEN_FILE` names a
file holding the same placeholder. A request that carries it — `Authorization: Bearer $SERVER_TOKEN` — reaches the
service with the real token in its place.

`VAR,src=PATH,to=HOST:PORT[,header=NAME][,file=FILEVAR]`:

- **`src=PATH`** — the token's only source: a file of yours alone (`chmod go-rwx FILE`; a link, or one other users may read, is
  refused), one line of printable characters without spaces, at most 1800 bytes. Never `-e`, never the command line. A
  file inside the sandbox's folder or anything a fenced session may read is refused — the session could read the
  token itself.
- **`to=HOST:PORT`** — the one destination, port required: `host.dozable.internal:PORT` (a port of this Mac also given
  with `--host-port`), a host name or an IPv4 address the permissions already allow (`--allow site:HOST:PORT`). A
  secret never opens anything: an unreachable destination is refused at launch with the flag to add. Never
  `mac.dozable.internal`, IPv6, your Mac's own addresses or a host Dozable already holds keys for.
- **`header=NAME`** — by default the token goes as `Authorization: Bearer TOKEN`; any other header gets it as it is.
- **`file=FILEVAR`** — also a file holding the placeholder (yours alone; in a sandbox `~/.doz-secrets/VAR`, in a fenced session
  under its own folder).

At most 4 per sandbox or session; VAR and FILEVAR are never one of Dozable's own variables (`ANTHROPIC_…`, `GH_TOKEN`,
`…_PROXY`, `DOZ_…`), and `-e VAR=…` for them is refused. `--unfenced` with `--secret` is refused: an unfenced session
has no proxy to hold it.

A chat room is one such service: Dozable's own chat server, reached on its page port with a participant's token, and
`dozchat` — on the PATH of every sandbox and fenced session — is the client that sends it ([Chat](36-chat.md#participants-and-tokens)).

**Only there.** The same placeholder sent to another port of the host, another host, or `mac.dozable.internal` is
refused (403) and logged — never forwarded with the token. A request that carries its own `Authorization` instead
passes untouched (and is noted with a fingerprint); the token is never added to it.

**Plain HTTP.** Every other credential placeholder is refused over plain HTTP. A secret's placeholder may be swapped
over plain HTTP only to this Mac's ports (`host.dozable.internal`) or a Tailscale address (`100.64.0.0/10`, a name
whose every address is in that range, or the address itself — and only while your Mac is on Tailscale itself: the
range is also used by mobile carriers), and only while the setting `network.placeholders_plain_http` is on (the
default; read when the secret is bound — at launch, a restart, or a new daemon). Anywhere else, use https:

```
refused by the sandbox proxy: a secret's placeholder is never sent over plain HTTP to 10.0.0.5:8080 — only to this
Mac's ports (host.dozable.internal) or a Tailscale address (100.64.0.0/10) while network.placeholders_plain_http is on; use https
```

**How long it lives.** The token is kept in a keychain item of its own (or, when the login keychain is locked, in the
daemon's memory — the launch says "kept until the daemon stops"), so a daemon restart and a session's restart keep it.
A sandbox's secrets end with its shutdown, reset or removal; a fenced session's when its record is removed (`doz
sessions end` of an ended session). Give the secret again to start again; giving it again for the same VAR replaces
the token (placeholders already handed out stay valid). `doz net NAME` shows each secret's destination, header and
fingerprint (`--json`: `secrets`), never the token; the agent's own facts say which variable holds a placeholder for
where.

## Change it — in the dashboard

On a sandbox's page, the details' **Network** tab › **What the agent can do** shows the presets (**Locked** ·
**Standard** · **Open**) and the permissions as switches, with its sites below. Flip a switch and it
applies at once; each permission's **hosts** unfold beneath it. When the agent was refused something, a line
says so — "The agent tried to install Python packages (PyPI)" — with **Allow** (or **Allow this
site**). A site is offered as its whole domain — the agent refused at `abc.frame.claudeusercontent.com` gets
**Allow claudeusercontent.com** (`site:*.claudeusercontent.com`), so a service that uses a new host name for
each request needs one approval, not one per address; `doz net allow NAME site:HOST` still allows a single
host. **Browse the web** asks you to confirm first. **Details: the rules and hosts** shows every
host behind the switches, and **Edit policy…** edits the raw rules with a preview of exactly what
changes.

![What the agent can do](images/permissions.png)

New sandbox shows the same switches (preset from the base you chose), and the **Settings** page
edits `defaults.permissions` with them.

## The network kinds

`--network` on `create` (and `network:` in `doz_project.yaml`) chooses how a sandbox is connected:

| `--network` | what it is |
|---|---|
| `agent` | proxied, with the **Standard** permissions (the default for agent images) |
| `locked` | proxied, **Locked**: the agent's model only |
| `open` | proxied, **Open**: everything, still logged |
| `bake` | proxied, package registries only (the default for `lab`, and what image preparation uses) |
| `nat` | a real network card through macOS's NAT: **not** filtered or logged |
| `none` | no network at all |

The proxied kinds have no network card: every connection, DNS included, goes through the proxy.
`nat` and `none` are the virtual machine's make-up, fixed when the sandbox is made.

## The raw rules

Under the permissions there are rules, which you can still edit directly:

```sh
doz net policy my-app                                   # show
doz net policy my-app --allow github.com --allow '*.githubusercontent.com'
doz net policy my-app --deny example.com --remove github.com
doz net policy my-app --preset open                     # replace with a preset: locked, bake, agent, open
```

Your own rules win over a permission's hosts. A host your rules can't allow doesn't even resolve.

## Settings

| key | default | what it does |
|---|---|---|
| `defaults.permissions` | `standard` | What a new sandbox's agent may do: `standard`, `locked`, `open`, or Standard with changes like `+web,-error-reports`. |
| `recipes.anthropic.claude-code.network` · `recipes.earendil-works.pi.network` · `images.lab.network` | `agent` · `agent` · `bake` | The network kind of a new sandbox of each image. |
| `defaults.nat_subnet` | (a free one) | The subnet of a new `nat` sandbox (`$DOZ_SUBNET`). |
| `network.host_ports_live` | `true` | Whether `doz net allow NAME host:PORT` may open a port of this Mac while a sandbox or session runs. |
| `network.placeholders_plain_http` | `true` | Whether a secret given with `--secret` may travel over plain HTTP — only ever to this Mac's ports and Tailscale addresses. |

## Limits and security

- **Browse the web** and **Open** let the agent send your code and data anywhere. Prefer a
  `site:HOST` for what the agent really needs.
- **A Dockerfile build runs outside this policy** (in Apple's builder); the sandbox made from it
  doesn't. See [Images and bases](08-images-and-bases.md#your-own-dockerfile).
- IPv4 only; HTTP/2 isn't passed through on the hosts whose traffic the proxy inspects; UDP is refused
  (programs fall back to TCP).
- **Your Mac's own addresses are never reachable**, whatever the permissions — Open included: its localhost, its
  Wi-Fi or Ethernet address, a VPN's or Tailscale's, link-local addresses and the cloud metadata address
  `169.254.169.254`. A port of your Mac you open to it is reached by name ([This Mac's ports](#this-macs-ports)), a
  model server's among them ([Claude Code and other models](32-claude-code-other-models.md)); other machines on your network stay reachable when the permissions allow them.
- There are no general port forwards from your Mac into a sandbox. The one exception is a sign-in's
  callback, briefly — see [Signing in from a sandbox](11-signing-in-from-a-sandbox.md).
- A sandbox made with an older version of Dozable keeps its rules; `doz net NAME` shows them as the
  permissions they amount to, and its first permission change stores them as permissions (anything
  no permission covers stays as your own site rules).

## Sessions on this Mac

A fenced session on this Mac (`doz run @mac`, fenced by default — [Sessions on this Mac](34-sessions-on-this-mac.md))
has the same kind of proxy, one per session: it reaches the network only through it, judged by the same permissions,
every connection logged. This Mac's **Standard** for such a session (`mac.permissions`) is its AI model, its own
updates, GitHub, error reports and the Node, Python, Go, Rust and Swift registries; `--permissions` decides for one
session, and the same commands change a running one with `--session`:

```sh
doz net @mac --session agent                      # its permissions and its refusals
doz net allow @mac --session agent install:ruby   # live
doz net log @mac --session agent --denied
doz net log @mac --session agent --fence          # what the fence itself refused (files, programs, services)
```

Inside the fence name lookups are closed (the proxy looks names up), a program that ignores the proxy has no network,
and listening is allowed only on the ports given with `--local-port N`. A service on this Mac is reached through the
proxy as `host.dozable.internal:PORT` for a port given with `--host-port PORT` (or `doz net allow @mac --session S
host:PORT`) — see [This Mac's ports](#this-macs-ports). An unfenced session (`--unfenced`) has none of
this: it reaches the network as you do, unlogged.

## Troubleshooting

| symptom | what to do |
|---|---|
| A package install fails | `doz net NAME` says what was refused and which permission allows it: `doz net allow NAME install:python`. |
| The agent can't reach your company's API | `doz net allow NAME site:api.example.com`. |
| A site works in your browser but not in the sandbox | `doz net log NAME --denied` shows the refused host — sites often use a second host for assets or APIs. |
| Claude Code can't update itself | `update` must be on (it is in Standard). |
| You need the whole web for a while | `doz net allow NAME web`, then `doz net deny NAME web` when done. |
