# The recipe format (schema 2)

A **recipe** tells Dozable how to install a coding agent, launch it, keep its state, give it its key without
the key ever entering the sandbox, and decide what it may reach. Each agent is one YAML file:

```
Sources/DozableKit/Recipes/agents/VENDOR/PRODUCT.yaml      ← what you edit
Sources/DozableKit/Recipes/compiled/PRODUCT.json           ← the same tree as JSON (generated, committed, embedded)
schema/dozable-recipe-2.schema.json                         ← the contract (JSON Schema, draft 2020-12)
```

The layout follows **Docker Sandbox Kit v3** (its `workload` descriptor): Kit's top-level fields, a `capabilities:`
list, Kit's own capability types where Kit has one, and Dozable's additions kept apart (under `dozable:` keys and in
`com.dozable/*` types). A Kit-shaped descriptor can therefore be produced from a recipe mechanically — see
[Kit v3, and exporting to it](#kit-v3-and-exporting-to-it).

**Contents:** [an example](#an-example) · [the top level](#the-top-level) · [capabilities](#capabilities) ·
[templating](#templating) · [strictness](#strictness) · [versioning](#versioning) ·
[Kit v3, and exporting to it](#kit-v3-and-exporting-to-it) · [adding a recipe](#adding-a-recipe) ·
[your own recipes and community catalogues](#your-own-recipes-and-community-catalogues)

## An example

Abridged from `Recipes/agents/xai/grok.yaml`:

```yaml
# yaml-language-server: $schema=../../../../../schema/dozable-recipe-2.schema.json
schema: 2
kind: workload
id: xai/grok
displayName: Grok Build
description: xAI's coding agent, on an xAI API key.
author: xAI
sourceUrl: https://github.com/xai-org/grok-build
licenses:
- Apache-2.0
args:
  version:
    default: 1.0.52
    pattern: '[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?'
    buildArg: GROK_VERSION
provides:
- com.dozable/grok@${{ kit.args.version }}
capabilities:
- type: com.docker.sandbox/network-policy@1
  config:
    runtime:
      allow: [api.x.ai:443, x.ai:443]                 # derived — see below
      deny: [cli-chat-proxy.grok.com:443, auth.x.ai:443, accounts.x.ai:443, console.x.ai:443]
    dozable:
      model:
        id: model:xai
        title: Talk to xAI
        hosts:
        - host: api.x.ai
          paths: [/v1/models, /v1/api-key, /v1/chat/completions, /v1/responses]
      update: []
      excluded: [cli-chat-proxy.grok.com, auth.x.ai, accounts.x.ai, console.x.ai]
- type: com.docker.sandbox/credential@1
  config:
    service: xai
    phase: runtime
    apiKey:                                           # derived from the key provider
      name: XAI_API_KEY
      proxyManaged: true
      inject: [{domain: api.x.ai, header: authorization, format: Bearer %s}]
    dozable:
      accounts: [key]
- type: com.docker.sandbox/volume@1
  config:
    path: /home/agent/.grok
- type: com.dozable/install@1
  config:
    kind: npm-platform-binary
    package: '@xai-official/grok'
    platform_package: '@xai-official/grok-linux-arm64'
    payload: bin/grok.br
    compression: brotli
    binary: grok
    integrity: sha512-GeIlno…
- type: com.dozable/launch@1
  config:
    command: [grok]
    no_prompts_args: [--always-approve]
    passthrough: [--version, -v, --help, -h, login, logout]
    env: {GROK_DISABLE_AUTOUPDATER: '1'}
    state_env: {GROK_HOME: /home/agent/.grok}
    status: none
    verify:
    - argv: [grok, --version]
      expect: grok ${{ kit.args.version }}
    check:
      argv: [grok, -p, say ok]
      expect: DOZ_FAKE_OK
# … auth@1, gateways@1, currency@1, directory@1
```

The files in the repository are written in block style (one value per line); any YAML that means the same is
accepted.

## The top level

Every key is required. Kit's own names, with Kit's meaning:

| Field | Meaning | Example |
|---|---|---|
| `schema` | This format's version: `2`. | `2` |
| `kind` | Kit's kind. A recipe is the agent a sandbox runs: `workload`. | `workload` |
| `id` | `VENDOR/PRODUCT`: the file's path under `Recipes/agents/`. `PRODUCT` is the agent's id (`doz try PRODUCT`), `[a-z][a-z0-9-]*`; `VENDOR` is its vendor's slug, `[a-z0-9]` and dashes. Together they are the tool's full name (`doz try anthropic/claude-code`; your own `mine/VENDOR/PRODUCT`, a community source's `NAME/VENDOR/PRODUCT`). | `anthropic/claude-code` |
| `displayName` | The agent's name as people read it. | `Claude Code` |
| `description` | One sentence. | `Anthropic's coding agent in your terminal.` |
| `author` | Kit's `author`: the publisher's name. | `Anthropic` |
| `sourceUrl` | Its source or documentation (https). | `https://code.claude.com` |
| `licenses` | SPDX identifiers. A licence SPDX has no id for is `LicenseRef-…` (SPDX's own form), with its words in `directory@1`'s `licence`. | `[Apache-2.0]`, `[LicenseRef-proprietary]` |
| `args.version` | Kit's arg for the version Dozable installs: `default` (the pinned release), `pattern` (the shape of a release), `buildArg` (its build-argument name in an exported Dockerfile), `description`. | `default: 2.1.227` |
| `provides` | Kit's `provides`, one entry, in Dozable's namespace: `com.dozable/PRODUCT@${{ kit.args.version }}`. | |
| `capabilities` | The list below. | |

## Capabilities

Each entry is `{type, description?, config}`. `type` says how `config` is read. A recipe has exactly one
network-policy, install, launch, auth, gateways and directory entry; at most one agent-context and currency entry;
one credential entry per key it uses, and one volume entry per state folder (in order).

### Kit's own types

Their `config` is Kit's shape exactly. Dozable's additions sit only under `config.dozable`, which an export removes.

**`com.docker.sandbox/network-policy@1`** — what the sandbox may reach.

| Field | Meaning |
|---|---|
| `runtime.allow` | **Derived.** `host:443` for each host of its model (the recipe's `dozable.model.hosts`, or its key provider's hosts for the shared Anthropic model) and each `dozable.vendor` host — in order, once each. |
| `runtime.deny` | **Derived.** `host:443` for each `dozable.excluded` and `dozable.quiet` host. |
| `dozable.model` | Its model permission: `id` (`model` — Anthropic's, shared — or `model:NAME`), `shared`, `title`, `summary`, `phrase`, `hosts`. |
| `dozable.update` | The hosts "Update itself" opens in its sandbox only. |
| `dozable.excluded` | Hosts kept out whatever is chosen (a sign-in Dozable does not offer, a host it must not use). |
| `dozable.vendor` | Hosts on its own maker's sites it calls at a normal start, each with its `reason`; allowed in its sandbox only. |
| `dozable.quiet` | Hosts it calls that no setting of its own turns off and that Dozable keeps out without counting a refusal (promptfoo's telemetry event; start-up requests of Kimi Code, Cline, Letta Code, Docker Agent, Nanocoder, CodeWhale, Maki and oh-my-pi). |
| `dozable.off_without` | Its own switches, set when a permission is off: `permission`, `env`, `says`. |

A host entry is `{host, paths?, exact_paths?, reason?}`: `paths` are prefixes (the proxy decrypts the connection to
judge them), `exact_paths` match exactly.

There is no `install` phase: Dozable's image preparation is not Kit's install hook. The bake reaches the base image's
registries and the recipe's `bake_hosts`.

**`com.docker.sandbox/credential@1`** — one per key the agent uses.

| Field | Meaning |
|---|---|
| `service` | The key provider (`providers.json`): `anthropic`, `openai`, `xai`, `google`. |
| `phase` | `runtime`. |
| `apiKey` | **Derived** from the provider: `name` (the variable holding Dozable's placeholder), `proxyManaged: true` (the proxy swaps the placeholder for the key, so the key never enters the sandbox), `inject` (one `{domain, header, format}` per provider host). |
| `dozable.accounts` | The Dozable account kinds that serve it (`mac`, `setup-token`, `api-key`, `codex-mac`, `chatgpt`, `openai-key`, `key`). |
| `dozable.env_aliases` | A recipe agent's: more guest variables that hold the same placeholder, for a tool that reads its key under another name (`OPENAI_API_KEY` beside an OpenAI-compatible base URL that points at the provider, `LLM_GEMINI_KEY`). Credential-shaped names, never the provider's own, never one the recipe sets. The placeholder works only on the provider's hosts, whatever the name it rides in. |

**`com.docker.sandbox/volume@1`** — one state folder kept with the sandbox: `path`, absolute (`/home/agent/…`).

**`com.docker.sandbox/agent-context@1`** — where Dozable writes the facts the agent reads about its sandbox:
`directory` and `filename` (`SKILL.md` for a skill); `dozable.kind` (`skill` or `context-file`), `dozable.manifest` (a
file written beside it: `{file, json}`), `dozable.launcher_arg` (the flag that also passes the facts on the command
line).

### Dozable's types

Kit has no type for these. An export keeps them as `optional: true` entries, which a Kit host skips.

**`com.dozable/install@1`** — how the agent is installed. The version is `args.version`.

| Field | Meaning |
|---|---|
| `kind` | `builtin` (Dozable's own installer: Claude Code, pi, Codex), `npm`, `npm-platform-binary` (the linux-arm64 program from a platform package), `manifest-binary` (the maker's release manifest), `pypi` (a Python tool and every dependency, hash-pinned — below), `release-binary` (one program from a release download — below). |
| `builtin` | `true` for the three agents Dozable's own code installs and launches. |
| `package`, `platform_package`, `payload`, `compression` | The npm package(s), the program inside, and `brotli` when it is compressed. |
| `manifest`, `url` | `manifest-binary`: the manifest's URL; the archive URL, a template with `${{ dozable.build }}`. |
| `binary` | The program, at `/usr/local/bin/BINARY`. |
| `needs_node`, `npm_args` | The Node major an npm install needs; extra `npm install` flags. Above 22 (the bases' Node), `24`: Dozable installs Node 24 under `/opt/node` for it on every glibc base, the Node base included, and runs the program on it (`platforms.musl: false`). |
| `bake_hosts` | Hosts the image preparation reaches beyond the base's registries. |
| `integrity` | The pinned release's sha512 (`sha512-…`). |
| `requirements` | `pypi` only: every distribution the tool's venv holds, one string each, `name==version --hash=sha256:<64 hex>` — the package itself and all its dependencies. |
| `extras` | Files the tool needs beside its program, from a pinned archive: `{url, sha256, path, to, what}` — an https `.tar.gz` (`${{ kit.args.version }}` in `url` and `path`), its sha256 (checked in the bake), the folder `path` inside it, unpacked to `to` (under `/opt/PRODUCT/`, root's, read-only to the agent). Fabric's patterns: `to: /opt/fabric/patterns`, and `launch.env` points the tool at them. Its host joins the bake's. |

**`pypi`** installs a Python tool from PyPI. The image gets Dozable's own Python (python-build-standalone CPython 3.13 for
aarch64 glibc, checksum-pinned, under `/opt/python` — the base's python3 is left alone, so the same wheels fit every
glibc base), a venv at `/opt/PRODUCT/venv`, and in it exactly the `requirements`: pip with `--require-hashes --no-deps`
downloads each one, checks its sha256, and installs nothing else; the package's own file is also checked against
`integrity` (its sha512, computed from the download when the recipe is written). `binary` is linked as
`/usr/local/bin/BINARY`. The lock is written once, in a scratch VM, from pip's own resolver (`pip install --dry-run
--report` against Dozable's Python, which lists each file and its PyPI sha256). The bake reaches PyPI
(`pypi.org`, `files.pythonhosted.org`) and GitHub's release hosts for the Python download. glibc only
(`platforms.musl: false`). A `pypi` recipe is prepared at its pin only: the lock belongs to that release, so nothing is
looked up and `latest` means the pin.

**`release-binary`** installs one program from a release download: `url` (https, with `${{ kit.args.version }}` in it);
when it ends in `.tar.gz`/`.tgz` or `.zip` it is unpacked and `payload` names the program inside, otherwise the download
is the program. Its sha512 is checked against `integrity`; it is placed under `/opt/PRODUCT` and linked as
`/usr/local/bin/BINARY`. Its download hosts go in `bake_hosts` (GitHub: `github.com` and
`release-assets.githubusercontent.com`). Like `pypi`, it is prepared at its pin only.

**`com.dozable/launch@1`** — how the agent runs.

| Field | Meaning |
|---|---|
| `command` | The program and its first arguments. |
| `no_prompts_args` | What turns its own approval prompts off (the sandbox is the boundary). |
| `no_prompts_env` | Variables set only when `no_prompts_args` would be put first (not with `ID.permissions = ask`, nor as root) — for an agent whose approval switch is a variable: MiMo Code's flag asks again on a terminal, its variable does not. |
| `model_args` | For a tool that takes its model only on its command line: the arguments that choose it (`[-m, $DOZ_MODEL]`, Cline's `[-P, $DOZ_MODEL_PROVIDER, -m, $DOZ_MODEL]`). Each `$DOZ_…` is a variable every `models@1` entry sets for its source (exactly one word names `$DOZ_MODEL`, none a credential). The launcher puts them first when `DOZ_MODEL` is set, unless the run gives its first flag itself or is a passthrough subcommand. A built-in agent's (pi's `--model`) are put on its default session by the host at session open, off its default source or with a model chosen — never baked. |
| `model_args_after` | Subcommands whose own flags `model_args` are (`run`, `exec`): there they go right after the subcommand (`docker-agent run --model X coder`). |
| `passthrough` | First arguments that run it as it is (`--version`, `login`). |
| `env`, `state_env` | Environment of every run; of its state folders (both baked). |
| `first_run` | An entry with `each_run: true` is written at EVERY run instead (a JSON file; its keys set, each `$DOZ_…` in a value the run's own, from `models@1`; skipped when the run has no source chosen; never a key — name the variable the placeholder is in, `$OPENAI_API_KEY`, for the tool to expand) — for a tool that takes its model only from its settings file (Crush). Otherwise: settings written into its config files, only the keys not there yet: `{file: ~/….json or ~/….toml, set: {dotted.key: value}}`; in a TOML file a key with no table (`schema_version`) is a top-level key, written above the first table; or a dotenv file, `{file: ~/…/.env, set: {KEY: value}}` (`KEY=value` lines — a key the file already has, even commented out, is kept; the file is made when missing; never a credential's name); a TOML key segment in double quotes is one key (`'projects."/workspace".trust_level': trusted` → `[projects."/workspace"]`); `format: json` for a JSON file whose name has no extension (Kimi Code's per-folder trust record); or a YAML file, `{file: ~/….yaml, set: {KEY: value}}` (top-level `KEY: value` lines only, each a string, number or bool — a key the file already has at the top level, even commented out, is kept; the file is made when missing). |
| `session_env` | Environment Dozable gives each session when it opens (never baked). |
| `session` | `shell` for a command-line tool that answers and exits (Fabric, llm): the default session is a login shell (`bash -l`) with the program on its PATH, named for the program. Absent: the session runs `command`. A shell session has no `resume`. |
| `service` | A background service the program starts and keeps, which holds the environment of the run that started it (OpenCode 2's `opencode serve --service`): `{args, restart, start?, env}` — its arguments after the program, what restarts it, what starts it when the restart fails (a stopped server the VM's init leaves as a zombie), and the variables compared (`[DOZ_MODEL]`; never a key's: placeholders differ per run). Before every run, the launcher restarts a service of the same user running with another value of one of `env` than the run sets, so a model or source chosen since applies. Plain words only (it is written into the launcher). |
| `status` | `osc7501` (it reports its state to Dozable) or `none`. |
| `resume`, `resume_check` | Arguments that continue its last conversation after a restart, and a check that there is one. |
| `verify` | Checks after preparation: `{argv, expect}`; `expect` may hold `${{ kit.args.version }}`. |
| `check` | Required. One headless turn `make recipe-check` runs in a fresh try: `{argv, expect, exit?, timeout?}` — `argv` runs as the agent through its launcher (approval prompts off), with fake keys and a stand-in model that answers `DOZ_FAKE_OK`; its output must contain `expect`, it must exit `exit` (default 0) within `timeout` seconds (default 240). `screen` (optional, `{expect?, refuse?, allow?, wait?}`): what the default session's first screen must show (`expect`, regular expressions) and must not (`refuse`, on top of the generic setup/sign-in/consent list), the lines the generic list excuses (`allow` — a ready screen's own banner), how long it settles (`wait`, default 15 s), and keys typed first (`keys`: `enter`, `esc`, `up`, `down`, `tab`, `space` — only for a choice nothing skips that is not the person's decision, to reach the screen checked: Antigravity CLI's colour scheme before its terms). See "Checking a recipe" below. |
| `settings` | Its settings keys before 0.37.34, when not the defaults (`images.ID_version`, `ID.permissions`): since then the names doz.toml still reads as aliases of `recipes.VENDOR.PRODUCT.version` / `.approvals`. |

**`com.dozable/auth@1`** — `methods`: the ways a person lets it reach its model, recommended first. Each is
`{kind, provider?, account?, accounts?, keys_page?, free_tier?, free_tier_note?, in_sandbox?, gateways?, note?,
checked?}`; `kind` is `api-key`, `vendor-sign-in`, `none` or `gateway`.

**`com.dozable/gateways@1`** — `entries`: how it works through each model gateway in Dozable's catalogue: `{gateway,
level (documented | verified | experimental | no | unknown), shape?, endpoint?, how?, proxy_route?, limits?, notes?,
evidence?, source?, checked?, reason?}`. `how` is `{env?, config?, args?, model_args?}`, whose values may hold
`${{ dozable.placeholder }}`, `${{ dozable.model }}` and `${{ dozable.gateway.endpoint.ID }}`. A gateway that `models@1` offers
needs no entry: it is `documented`, citing the shape's `source` (or the native entry's `docs`). An entry for it only
overrides that — `verified` with its evidence once `make recipe-check` has run the tool through it — and needs no `how`.
Every gateway models@1 does not offer has an entry (`no` with its reason, or `unknown`); a recipe with models@1 may not
call one `documented`/`verified`/`experimental` that a try cannot use, nor `no` one it offers.

**`com.dozable/models@1`** — which model sources it can be tried with, and how a choice reaches its own settings.
See [Model sources](#model-sources-providers-and-gateways).

**`com.dozable/currency@1`** — `checked` (when the recipe was last checked against the real agent) and
`lifecycle` (`{status: current | superseded | retired | discontinued, by?, note?, source?, checked?}`). How fresh the
agent's releases are is measured on each Mac, never recorded here.

**`com.dozable/directory@1`** — what the directory index, `doz search` and the Quick try show: `kind` and
`categories` (see [Kinds and categories](#kinds-and-categories)), `aliases`,
`icon` (a product in the icon registry), `default_base`, `platforms {glibc, musl}`, `limits` (`{musl?, base?,
reason}`), `tags` (`{tag, level, evidence?, source?, notes?, checked?}` — the tags no other field can derive),
`terms`, `licence` (the licence in words, when it is not just the SPDX id), `published` (absent: published).

**The subject** (optional) — what the recipe's agent is, in 1–5 lower-case words, shown beside its name: `coding
harness` (pi), `agentic tool` (Fabric), `agentic fortune teller`. Without one, its agent is "agent", and generic copy
always says "agent". It is the Kit `description` of the `com.dozable/directory@1` entry:

```yaml
- type: com.dozable/directory@1
  description: coding harness
  config:
    kind: coding-agent
```

That field is Kit's own, and every schema 2 reader already takes it, so a doz from before the subject still accepts a
catalogue whose recipes carry one (no `minimum_doz` needed). The schema checks its shape (`^[a-z][a-z0-9]*( [a-z0-9][a-z0-9-]*){0,4}$`,
at most 40 characters).

**`com.dozable/settings@1`** (optional, at most one) — the agent's own settings beyond the ones every recipe has.
Every recipe's agent has `version`, `approvals` (when it has approval prompts to skip), `memory_mib` and `network`,
generated for it; their doz.toml keys are `recipes.VENDOR.PRODUCT.NAME` (`[recipes.anthropic.claude-code]`, a recipe
that is not Dozable's one part longer: `[recipes.mine.VENDOR.PRODUCT]`). A recipe declares more only when its agent
needs one of its own: `options`, 1–8 of `{name, type, default, summary, applies, choices?, min?, max?}` — `type` is
`bool`, `int` (with `min` and `max`) or `choice` (with its `choices`), closed; `applies` is `now`, `next-session` or
`next-create`; a name is never one of the four every recipe has. Each is set on the Mac (`doz config set --agent ID
NAME VALUE`). Codex's `keep_alive` is the one today. A new capability type: an older doz refuses a recipe that has
one, so a catalogue recipe uses it only with the catalogue's `minimum_doz` raised (a built-in recipe ships with its
doz).

**`published: false`** unpublishes a recipe: it stays in the build and valid (its YAML is checked like any other), and
everything STORED of it keeps working — a sandbox, its image (a rebuild included), its settings, its account — but it
is in no list a person picks from (the Quick try, New Sandbox, `doz try`, `doz search`, the directory index,
onboarding's image choice, the settings listed), a NEW sandbox of it by name is refused ("… is unpublished in this
version of Dozable"), and the per-recipe work skips it: `make recipe-check RECIPES=all` and `--changed`, the nightly
profiles, `make agent-currency` and the host's hourly look-up of its latest release (unless an image or sandbox of it is
in the store). Naming it still runs it (`make recipe-check RECIPES=grok`). `Scripts/recipes_published.py` is the one
reader of the flag for the scripts. Publishing it again is deleting the line. A gateway is unpublished the same way:
`"published": false` on its entry in `Recipes/gateways.json` (every recipe still describes it; an existing key of it
keeps working; `--gateway` refuses it for a new sandbox).

**`com.dozable/guide@1`** (optional, at most one; every shipped recipe has one) — its companion guide: intro, first
steps (the first with a command is its check turn), tips, docs, a notice. See [The guide](#the-guide).

**`com.dozable/ports@1`** (optional, at most one) — the web ports the program serves inside the sandbox, each
forwarded to the Mac's loopback (`127.0.0.1`) while the sandbox runs, with an Open button ([Web
ports](../manual/29-web-ports.md)). `ports`: 1–16 of `{port, title, path?, protocol?, auth?, token_hint?, check?}` —
`port` the guest port its program listens on (its own localhost), `title` the button's label (1–40 characters),
`path` what Open opens (default `/`), `protocol` `http` (default) or `ws` (forwarded, no button), `auth` `none`
(default), `token` (the program prints a token — `token_hint` says where) or `login`, `check` what `make recipe-check`
GETs (default `path`; any HTTP status line passes). `serve`: the command that serves them when the session's program
does not (`[aichat, --serve]`) — `make recipe-check` runs it in the background before it GETs each http port through a
real forward. The forward is inbound only: it is not egress, the network policy and the proxy do not apply to it, and
no credential crosses it.

```yaml
- type: com.dozable/ports@1
  config:
    ports:
    - port: 8000
      title: AIChat web
      path: /playground
    serve: [aichat, --serve]
```


## The guide

`com.dozable/guide@1` is the recipe's companion guide: the Guide tab of the sandbox page (first, and chosen, on a
try), `doz guide NAME`, the "Start here" `doz try` prints before it attaches a tool whose session is a shell, and a
one-time note in that shell's first login.

```yaml
- type: com.dozable/guide@1
  config:
    intro: "Fabric applies ready-made prompts — patterns — to text you pipe into it. It is not a chat: it answers in your shell and exits."
    steps:
    - text: "Check it answers."
      command: 'echo hello | fabric "say ok"'       # the check turn, as a person types it
    - text: "See the patterns it has."
      command: "fabric -l"
    - text: "Use a file from your folder — put it there first, then change the name:"
      command: "fabric -p extract_wisdom < notes.md"
      edit: true                                     # typed, never run: the person changes it first
    tips:
    - "`fabric -s` streams the answer as it comes."
    docs: https://github.com/danielmiessler/Fabric
```

- **`intro`** — one or two sentences: what it is, and whether it is a chat, an agent with its own screen, or a tool
  that answers in the shell and exits (≤ 400 characters).
- **`steps`** — 1 to 8 `{text, command?, edit?}`. The first step WITH a command is the recipe's `launch@1.check` turn as a
  person types it (`sh -c X` is X; `${{ dozable.model }}` is the variable models@1 sets to it, `"$DOZ_MODEL"`), so the
  first thing a person runs is known to work. Every command starts with the tool's program, its session's command, its
  short name, or a plain shell builtin (`echo`, `printf`, `cat`, `ls`, `cd`, `mkdir`, `head`, `tail`, `export`), is one
  line, its quotes closed. `edit: true`: the page types it and never presses Enter. A step without a command may come
  before it — what the person meets at the first start that Dozable leaves to them (Antigravity CLI: Google's terms).
- **`notice`** — optional, one line (≤ 200 characters) `doz try` says first: that same thing, in short.
- **`tips`** — at most 6, `code` in backquotes (the page draws it as code, never as markup); **`docs`** — https.

Dozable adds the rest, never the recipe: the preamble (what kind of thing it is, how to use it here) and "This try" —
the version (the pin), the provider and model with the account's NAME ("your key stays on the Mac"), the network, the
folder (the Mac's path) and where its settings live. `make recipe-check` runs every step with a command after the check
turn's that is not an edit, in a shell in the try (exit 0).

## Families: a tool's majors

When a tool's new major release line is a different program (OpenCode 2: another npm package, another config, a
background server), each major is a recipe of its own, and `com.dozable/family@1` ties them together:

```yaml
- type: com.dozable/family@1
  config:
    family: opencode          # what a person types: the recommended major
    major: 2
    title: OpenCode 2
    recommended: true         # exactly one per family
```

- `NAME` is the family's recommended major, `NAME@MAJOR` a major, `NAME@VERSION` an exact release of the major it
  belongs to (`AgentRef`). A member named by its own id (`opencode2`) is that major.
- With its vendor: `VENDOR/FAMILY` (`anomalyco/opencode`), `VENDOR/FAMILY@MAJOR`, `VENDOR/ID` (a member's own id is
  that major) — the members of a family share one vendor (validated).
- The family's name is the id of one of its members — the one that predates the family. Its sandboxes, image, settings
  and statistics keep that id, so an existing sandbox never changes major. No other recipe or alias may use the name.
- Each member pins a release of its own major. Its `latest` stays within that major: when the package's `latest` tag is
  another major's, Dozable takes the newest stable release of its own.
- Each major has its own guide, check, network profile and statistics id.
- Move `recommended` to a new major only once its recipe passes `make recipe-check`, in a commit of its own. It is
  "recommended", never "latest".

## Kinds and categories

Every recipe says what it is, in `directory@1` — declared, because nothing else in its data can say it:

```yaml
- type: com.dozable/directory@1
  config:
    kind: ai-tool                # coding-agent | ai-tool: the two sections of New Sandbox, the Quick try and doz try's list
    categories:                  # one or more, from the vocabulary; the Quick try's filter pills, doz search --tag
    - terminal-tool
```

The vocabulary is `Recipes/tags.json` (`kinds`, `categories`, beside the capability tags), each word with a title and
what it means:

| Category | For | Kind |
|---|---|---|
| `coding-agent` | edits and runs code in its folder, turn by turn | coding agents only |
| `personal-agent` | a general assistant acting with shell, file and web tools | either |
| `terminal-tool` | a command-line helper: chat REPL, one answer, a shell command | AI tools |
| `framework` | a library or kit for building agents and LLM apps | AI tools |
| `browser-agent` | drives a web browser | AI tools |
| `mcp` | Model Context Protocol servers, gateways, inspectors | AI tools |
| `research` | searches, reads and reports | AI tools |
| `evaluation` | tests and red-teams prompts and models | AI tools |
| `workflow` | builds automations and pipelines | AI tools |
| `local-models` | runs models inside the sandbox | AI tools |
| `chat-app` | a chat web app for your models | AI tools |

The loader refuses a recipe without a kind or a category, a word that is not in the vocabulary, a category twice, or a
category of the other kind. An entry of `Recipes/known.json` (one that is coming) carries `kind` and `categories` too,
so the directory, `doz search --tag` and the Quick try's sections include it. A new word is a change to tags.json, the
schema's enum and this table together (`CategoriesTests` holds them to each other).

## Model sources: providers and gateways

A **model source** is where a key goes: a provider (`anthropic`, `openai`, `xai`, `google`, `opencode`) or a gateway
(`openrouter`, `vercel-ai-gateway`) — or a source that takes no key (`opencode-zen`, below). Each is a key provider in `Recipes/providers.json` — its hosts, the header its key
rides in, the variable its placeholder is in, its check — and each lists its **endpoints**: the API shapes it serves
(`openai-chat`, `openai-responses`, `anthropic-messages`, `gemini`), the base URL of each, and a default model (a
gateway's is `creator/name`). Gateways take their endpoints from `Recipes/gateways.json`.

A recipe says what it can speak, and nothing about keys:

```yaml
- type: com.dozable/models@1
  config:
    default: xai                         # the source a try uses when none is chosen
    shapes:                              # the shapes it speaks to ANY source's base URL, preferred first
    - shape: openai-chat
      env: {API_BASE_URL: '${{ dozable.base_url }}', DEFAULT_MODEL: '${{ dozable.model }}'}
      key_env: [OPENAI_API_KEY]          # where it reads the key for this shape
      source: https://…                  # where the tool documents taking a base URL, key and model
    native:                              # the sources it reaches through its own client (no base URL)
    - source: anthropic
      env: {DEFAULT_MODEL: 'anthropic/${{ dozable.model }}'}
      docs: https://…                    # optional: where the tool documents this source
    models:                              # optional: a default model per source, over the source's own
      openrouter: openai/gpt-5.4-mini
```

`launch@1.check.argv` may name `${{ dozable.model }}` too: `make recipe-check` runs the check turn once per source the
recipe is offered (in a fresh try with that source's fake key) and puts that source's model there.

- **What it is offered:** every source with an endpoint speaking one of `shapes` (the first shape listed that the source
  serves wins), and every source named in `native`. So a tool that takes an OpenAI-compatible base URL (`openai-chat`
  or `openai-responses`) is offered OpenRouter and Vercel AI Gateway without naming them; its gateway entries follow
  (see `gateways@1`), and so do `--gateway`, the plan, the Quick try's "Through a gateway" and `doz search`. `except` (a list of source ids) leaves sources out a shape would
  offer. The try setup, New Sandbox, `doz try --provider SOURCE` (`--gateway` is the same flag) and `doz create` offer
  exactly these.
- **What a choice does:** at every session open and every `doz exec`, Dozable sets the chosen entry's `env` (never over a
  value the caller gave), with `${{ dozable.base_url }}` = the source endpoint's base URL and `${{ dozable.model }}` = the
  sandbox's model (`--model`, else `models.<source>` here, else the source endpoint's default). Nothing is baked: one
  image serves every source.
- **The key is Dozable's, never the recipe's.** The sandbox's account decides the source (its kind and provider); the
  proxy holds that source's key and swaps it ONLY into requests to that source's own hosts (providers.json /
  gateways.json — a recipe cannot add one). The placeholder is put in the source's own variable
  (`OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `AI_GATEWAY_API_KEY` …) and in the chosen entry's `key_env` names
  (credential-shaped, validated). A recipe-chosen base URL is therefore harmless: the placeholder sent anywhere else is
  refused by the leak guard, and the key never leaves the Mac.
- **Its model permission** reaches the hosts of every source it is offered (validated), so a sandbox can use the source
  its account names.
- **Accounts:** an Anthropic source takes an Anthropic API-key account (`--api-key`; never a Claude subscription), an
  OpenAI source an OpenAI API-key account (`--openai-key`; never a ChatGPT sign-in), every other source a `key` account
  of that provider (`doz account add NAME --provider openrouter`).
- A recipe without `models@1` keeps its one credential exactly as before (Codex's own account flow is untouched).
  The built-in pi declares native sources; the built-in Claude Code (660) declares `anthropic` natively — its own
  accounts, this Mac's login and setup tokens included, and its own model unless one is chosen (`launch.model_args`,
  put on its default session only then) — the `anthropic-messages` shape (a gateway's Anthropic endpoint, the key's
  placeholder in `ANTHROPIC_AUTH_TOKEN`) and `local`.
- **A model server on this Mac** (`local`, 660 — Ollama, LM Studio, llama-server, LiteLLM, vLLM, oMLX) is offered only
  by a `native` entry, which may name `${{ dozable.base_url }}`: `http://mac.dozable.internal:PORT`, the port the
  sandbox was made with (`--local-port`; no port, no selection). It takes no key: no account, no binding, no
  placeholder; the entry's `key_env` names get a fixed non-secret word (`dozable-no-key`) for a tool that insists on
  one. The proxy routes that one name and port to the Mac's `127.0.0.1:PORT` and refuses every other way to the Mac's
  loopback, whatever the policy. It has no model list: the model is named (`--model`), required.
- **A source that takes no key** (`opencode-zen`: OpenCode Zen's free models) is listed under `keyless` in
  `Recipes/providers.json` — its hosts, its endpoints, and the models Dozable lists for it, each with its data terms as the
  source's docs state them (its own model list has no prices, so a free model cannot be told from a paid one): the
  free models the docs list that the tool's pinned release can use without a key; `checked` is when the list and terms
  were last compared with the docs and that release. It is never a key provider: no binding, no placeholder,
  no account (`doz account add` refuses it), and its hosts may be no provider's. A recipe is offered it only by a
  `native` entry — a shape alone never offers it, since only the tool that knows it can use it. A try with it has no
  account at all (`--account` is refused); the leak guard still watches its hosts, so a placeholder sent there is
  refused. Its hosts go in the recipe's model permission path by path (only the requests the tool makes for a model:
  `/zen/v1/chat/completions` and `/zen/v1/responses` for OpenCode 2, and `/inference/openai/v1/…` the same two from
  2.0.32, which moved them), so nothing else of that site is reachable.
- **A key confined to paths** (`opencode`: OpenCode's key — one `OPENCODE_API_KEY` for OpenCode Zen's `opencode/…` and
  OpenCode Go's `opencode-go/…` models) is a provider with `paths`: the paths of its hosts the key may go to (prefixes;
  an entry ending in `$` is that path exactly). It must be `swap_only` — the key only ever replaces a placeholder the
  request carries, never added to one without — and the proxy refuses its placeholder on any other path of the host (or
  a path with a dot segment or an encoded `/`, `.` or `\`), whatever the network allows. `also_headers` names the other
  headers its placeholder is swapped in, in place (OpenCode's Anthropic-shaped models send the key in `x-api-key`, its
  Google-shaped in `x-goog-api-key`; the rest in `Authorization: Bearer`). It serves no shape, so a recipe is offered
  it only by a `native` entry, and that recipe's model permission must name every one of its paths (validated). Its
  `models` (with `docs` and `checked`) are listed like a key-less source's — no public list carries OpenCode Go's — the
  first the default. Such a provider may share a host with a key-less source (OpenCode Zen's free models carry no
  placeholder, so nothing is swapped into them). OpenCode 2's paths are its model requests under `/zen/v1/`,
  `/zen/go/v1/` and (from 2.0.32) `/inference/…`, per API shape, plus `GET /console/api/v2/config` — the one read of
  the key's OpenCode Console settings it makes when it starts (workspace `probes/656-*/read-bundle.py`).

## Templating

Kit's syntax, `${{ NAME }}`. A recipe may use exactly these, and only in the fields named above:

| Template | Where | Value |
|---|---|---|
| `${{ kit.args.version }}` | `provides`, `launch@1.verify.expect` | The release (in `expect`, without a `+build` part). |
| `${{ dozable.build }}` | `install@1.url` | The release's `VERSION-BUILD` path segment (`manifest-binary`). |
| `${{ dozable.placeholder }}` | `gateways@1` `how` | The gateway key's placeholder. |
| `${{ dozable.model }}` | `gateways@1` `how` | The model chosen. |
| `${{ dozable.gateway.endpoint.ID }}` | `gateways@1` `how` | The gateway endpoint's base URL. |

Any other name is an error, and so is the old `{name}` form.

## Strictness

As in Kit: **an unknown key anywhere is an error**. That covers the top level, every capability entry, every Kit
config and every `dozable:` block. A capability type this build does not know is an error, and so is a second copy of
a single one. The **derived** parts (`runtime.allow`, `runtime.deny`, a credential's `apiKey`) must equal what Dozable
derives, so they can never drift from the data they describe; the error says the expected value.

The JSON Schema states the shape. The loader (`RecipeDocument` in DozableKit) refuses whatever the schema refuses, and
also checks what only Dozable can: the derived parts, the templates, and the agent's own rules (exact host names, no
credential in an environment variable, a pinned release that is well formed). The tests hold the two together.

The YAML is read with YAML 1.2's core schema: `true` and `false` are the only booleans (`no` and `on` are words),
and a date stays a string. Anchors, aliases and merge keys are refused, so a recipe is plain data.

## Versioning

`schema: 2` promises the shape `schema/dozable-recipe-2.schema.json` describes. Within schema 2:

- A new **optional** field, or a new capability type, may be added. An older Dozable refuses a recipe that uses it,
  because unknown keys are errors. Dozable's own recipes ship with Dozable, so they always match — and a **recipe
  catalogue** (recipes published without a release, docs/DOZABLEKIT.md, *The recipe catalogue*) names the oldest doz
  that reads every file in it (`minimum_doz`): an older doz keeps its own recipes rather than refuse one.
- A field is never renamed, removed or given a new meaning. That needs `schema: 3`, with a new schema file beside
  this one.
- Kit's capability versions (`network-policy@1`, …) are Kit's. When Kit moves one (`network-policy@2` exists), a
  recipe moves to it in a new schema version, not silently.

## Kit v3, and exporting to it

| Dozable recipe | Kit v3 descriptor |
|---|---|
| `schema: 2` | `schemaVersion: "3"` |
| `id` (`VENDOR/PRODUCT`) | the image reference the kit is published under |
| `kind`, `displayName`, `description`, `author`, `sourceUrl`, `licenses`, `args`, `provides` | the same fields |
| `network-policy@1`, `credential@1`, `volume@1`, `agent-context@1` | the same entries, each `config.dozable` removed |
| `com.dozable/*@1` | kept as `optional: true` entries (a Kit host skips an optional type it does not know); `${{ dozable.NAME }}` written as `{dozable.NAME}` |
| `install@1` + `launch@1` | a generated Dockerfile: `ARG` from `args.version.buildArg`, the install steps, `ENV`, `ENTRYPOINT` |
| `directory@1` `icon` | `iconUrl` (the registry's published https URL) |

Kit has no type for first-run settings that **merge** into a config file: `lifecycle@1`'s `files` write whole
files. So `first_run` lives in `launch@1`, and a recipe has no `lifecycle@1` entry. A `lifecycle@1` holding only a
`dozable:` block would be empty after export, which Kit refuses.

A test builds this view of every recipe in memory and validates it against Kit v3's own published JSON Schema,
vendored in `Tests/Fixtures/kit-v3/`. It also checks Kit's cross-entry rule that every credential inject domain is
allowed. An export command that writes the descriptor and its Dockerfile comes later, once Kit's specification is
final.

## Adding a recipe

1. **Write `Recipes/agents/VENDOR/PRODUCT.yaml`**, starting with the `# yaml-language-server:` line (editors then
   check it against the schema as you type). Copy the closest existing recipe.
2. **Its key provider** must be in `Recipes/providers.json`. The credential's `apiKey` is derived from it.
3. **Its mark:** add a product (and its vendor, if new) to the icon registry, `Recipes/icons/icons.json`, and name
   it in `directory@1`'s `icon` (docs/DOZABLEKIT.md, *The icon registry*).
4. **Embed it:** add `.embedInCode("Recipes/compiled/PRODUCT.json")` to Package.swift, and the file to the two lists
   in `AgentRecipes` (`embedded()` and `compiledFiles`, AgentRecipe.swift). `AgentKind` follows the recipes by itself.
5. **`make recipes`** writes `Recipes/compiled/PRODUCT.json`. Commit both files.
6. **Profile its network:** `make profile-agents AGENTS=PRODUCT` records every endpoint its first start calls
   (`profiles/PRODUCT.json`). Decide each one, then allow it (vendor, model), keep it out (`excluded`), or turn it off
   with its own setting (`first_run`, `off_without`).
7. **Its currency:** `make agent-currency` records its latest release and how fresh it is.
8. **Test:** `make test` checks the schema, the loader, the Kit view, the profile decisions and the first-run
   settings. `make recipe-check RECIPES=PRODUCT` proves it builds, starts and answers in a real sandbox (below).
9. **Ship it** with the next release — or, between releases, in a recipe catalogue: `make publish-recipes` signs the
   tree's committed compiled data, checks that this build's doz uses it, and writes it beside the update feed
   (pushed only with `PUSH=1`). Installed doz pick it up at their host's next start. The built-in agents (Claude Code,
   pi, Codex) never come from a catalogue.

## Checking a recipe

`make recipe-check RECIPES="grok gemini"` (`RECIPES=all`: every recipe) runs each recipe for real, in a scratch store
(`RECIPE_STORE`, default `/tmp/doz-recipe-check`; prepared images are kept there between runs, sandboxes never are):

1. **Build** its image at the pinned release (the registries are not asked for a newer one) — the bake checks the
   pin's integrity and runs `verify`.
2. **Verify** — each `verify` command again, in a sandbox, its output compared with `expect`.
3. **A fresh try** with fake keys held in the host's memory; the model's hosts (xAI, Google, Anthropic, OpenAI) go to
   a stand-in on this Mac (`Scripts/fake-provider.py`, TLS with its own throwaway CA) that answers `DOZ_FAKE_OK`.
4. **The smoke turn** — `check.argv` as the agent; its output must contain `check.expect`, its exit status be
   `check.exit`. The stand-in must have seen the fake key, swapped in by Dozable's proxy, while the guest holds only a
   placeholder.
5. **No key in the guest** (its processes' environments, home folders, `/tmp`, `/run`, `/etc`), and **the leak
   guard**: the placeholder sent to another provider's host is refused and never reaches it.
6. **Its status** — for `status: osc7501`, an interactive turn in its default session: Dozable must see it report at
   least `idle`, `working` and `done`.

Before any of the try's commands run (step 3 onwards), **its first screen**: every recipe whose default session is the
agent (not `session: shell`) has that session opened on a terminal, nothing typed, left to settle (`check.screen.wait`,
default 15 s), and its screen read back. It must be the agent ready to work: no setup wizard, onboarding, sign-in,
usage-data consent, trust or theme question, no request for a key (a generic list in `Scripts/recipe-check.py`,
`SETUP_SCREEN`; a line `check.screen.allow` matches is excused), each `check.screen.expect` found and no
`check.screen.refuse`. A headless check turn never sees such a screen — a person's first try does (Goose ran its own
setup whenever its `config.yaml` was missing, whatever the environment said). `RECIPE_ONLY=screen` runs this check
alone, for a quick look at every agent's first screen.

It exits non-zero when any step fails and writes a JSON report (`RECIPE_REPORT`, default
`$RECIPE_STORE/report.json`): per recipe pass/fail, the version, each step's duration, the states seen and the
failures. The **Recipes** workflow (`.github/workflows/recipes.yml`) runs it on a self-hosted Mac for every change to
a recipe, the stand-in or the harness, and every night for all of them with `make agent-currency`,
`make profile-agents DIFF=1` and `make recipe-audit`.

### The ingredient audit

`make recipe-check` proves a recipe works at its pin; **`make recipe-audit`** (`Scripts/recipe_audit.py`) proves that what
the pin names is still there and still the same bytes — no VM, no key, read-only requests to the public registries. For
every published recipe (`RECIPES="a b"`: any, unpublished included), one line per ingredient, each **ok**, **changed**,
**behind**, **gone** or **unchecked**, with why:

| Ingredient | Checked against |
|---|---|
| `pin` | `npm`, built-in: the version's `dist.integrity` on npm (Codex: its `-linux-arm64` version); `npm-platform-binary`: the main package at the version exists and the platform package's integrity is the pin's; `manifest-binary`: the vendor manifest's sha512 while it still names the pinned build, else the archive downloaded; `release-binary`: the download's sha512, cross-checked with GitHub's own asset digest; `pypi`: the package file the lock names is one PyPI publishes for the release, and its download's sha512 is `integrity`. |
| `requirements` | `pypi`: every lock line's sha256 is one PyPI publishes for that release. |
| `extras[N]` | each `install.extras` URL still serves the bytes its `sha256` names. |
| `latest` | the newest release from `profiles/currency.json` (`make agent-currency`'s data — not looked up again): `behind` when the pin is older. A family member's newer *major* is another recipe, so it is not `behind`. |

Once per run it also checks the shared ingredients: every base image's pinned digest still resolves on its registry (a
tag that has moved on is `behind`), the Node and Python runtimes' pinned sha256 are the ones their publishers list, and
Claude Code's native build checksums. The recipe's network hosts, auth methods, gateway levels, default base and
lifecycle are recorded as they are, never judged (the network profiles do that).

Downloads are bounded (400 MiB) and their hashes cached by URL with the server's ETag, Last-Modified and length
(`RECIPE_AUDIT_CACHE`). A timeout, a 5xx or a rate limit is **unchecked** — only a 404/410 is **gone**. The run exits
non-zero on any **changed** or **gone** (a pin whose bytes moved under it is a supply-chain alarm); **behind** and
**unchecked** are information. It writes `profiles/audit.json` (the published set only; sorted and dated, so two runs
the same day are identical) and prints a table; `RECIPE_AUDIT_SUMMARY` appends a Markdown summary,
`RECIPE_AUDIT_REPORT` writes the JSON elsewhere too.

**The refresh is proposed, never applied by itself.** `make recipe-audit PROPOSE=1` rewrites, for each **behind**
recipe that is not built-in, the YAML's pin — `args.version.default`, the install `integrity` and each extras `sha256` —
from the registry, verified against a download (npm's integrity against the tarball, GitHub's digest against the
release asset, the manifest's sha512 against the archive), then runs `make recipes`. It never commits, pushes or
publishes, and a `pypi` recipe is never proposed (its lock is resolved in a scratch VM). A proposal is committed only
after `make recipe-check RECIPES=ID` passes and `make profile-agents AGENTS=ID` is re-run for the new release.

## Your own recipes and community catalogues

The same format serves recipes that are not Dozable's: a person's own (`<settings dir>/recipes/mine/ID.yaml`, made with
`doz recipe new` or `doz recipe add FILE`) and the recipes of a **community catalogue** (added by its URL and its
publisher's Ed25519 key with `doz recipe source add`, the key's fingerprint confirmed before anything is fetched). The
user manual's "Your own recipes, and community catalogues" walks through both; this section is the contract.

**Origins.** Every recipe has one — Dozable's, yours, or a community source's — shown with it everywhere ("yours",
"community · NAME"). It is not part of the file: the same YAML is Dozable's in this tree and yours in your settings
folder. A recipe that is not Dozable's:

- may never use an id or alias of Dozable's set (the embedded recipes or Dozable's signed catalogue) — it is refused,
  never used to shadow Dozable's; a community source offering an id already taken (by yours, or by a source added
  earlier) is refused whole;
- installs exactly its pinned release (`latest` means the pin; nothing is looked up), wears no mark from the icon
  registry (a lettermark is drawn), and is never counted in usage statistics;
- is kept, unpublished, when it is removed, so the sandboxes made from it keep working — and its id stays theirs;
- is named in full with its source first: `mine/VENDOR/PRODUCT` (yours), `NAME/VENDOR/PRODUCT` (a community source's —
  the name it was added as; `dozable` and `mine` are never a source's name). `VENDOR/PRODUCT` alone always means
  Dozable's recipe, so a community recipe cannot pass as one by choosing a vendor's slug. Its `id`'s `VENDOR` must be well
  formed like any recipe's (the `document` requirement).

**The minimum requirements for a community recipe** (`CommunityRequirements` in DozableKit — a closed list; every
recipe that is not Dozable's must meet all of them to be used; `doz recipe check` prints them item by item):

| id | requirement |
|---|---|
| `document` | a schema 2 recipe, read strictly (this page's [strictness](#strictness)) |
| `validators` | every rule Dozable's own recipes pass — its own, and among all recipes (ids, aliases, model permissions, families) |
| `not-dozable` | its id and aliases are none of Dozable's |
| `not-builtin` | not a built-in agent (`install@1` `builtin` is Dozable's own installer) |
| `about` | `author`, `sourceUrl` (https), `licenses` and `description` filled in — none empty, none `TODO` |
| `plain-text` | no control (C0, DEL, C1) or bidirectional-control character in any string; `displayName` ≤ 60 characters, `description` ≤ 300, `author` ≤ 80 |
| `pinned` | an exact version (never `latest`), an `integrity`, every `extras` entry with its sha256 |
| `guide` | a `guide@1` and a `launch@1.check` |
| `no-credential` | no variable the recipe sets is a credential's name; no key-shaped value anywhere in it |
| `no-quiet` | no `dozable.quiet` hosts (a refusal hidden from the person); `excluded` only narrows and is allowed |
| `reach-shown` | no `dozable.vendor` hosts (a hidden permission): what it reaches is its model and update hosts, shown in the plan |
| `no-mark` | no `directory@1` `icon` |
| `no-family` | no `family@1` |

**The full check** (`doz recipe check ID --full`) is `make recipe-check`'s core, run by an installed `doz` (it cannot
assume Python): this executable as child processes in a scratch store under the guarded test environment, fake keys,
and a Swift stand-in model provider (`StandInProvider`: xAI, Google, Anthropic, OpenAI and the two gateways, over TLS
with a throwaway CA) behind the existing provider seams. It builds the image at its pin, takes a fresh Locked try,
reads its first screen, runs `verify` (before and after the turn), the check turn (the stand-in must see the fake key,
swapped in by the proxy), the guide's later steps, and checks the guest for keys and the leak guard. It does not
check OSC 7501 states, web ports, model sources other than the default, tool-call-only answers, Google Stitch or OpenCode
Zen — those stay `make recipe-check`'s. A pass is recorded with the sha256 of the bytes that passed.

**A community catalogue** is the [recipe catalogue](../DOZABLEKIT.md) format (`format: 1`, the same signed message
prefix) with `"product": "doz-community-recipes"` and ONLY `agents/<id>.json` files (each a compiled recipe — `doz recipe
show FILE --document`); no providers, gateways, tags, known entries or icons (those stay Dozable's). It is signed with
its publisher's own Ed25519 key — never Dozable's (refused as a source key). `minimum_doz` is honoured; `source_version`
is informational. A doz verifies the signature with the key the person confirmed, checks every file's sha256 and size,
and uses it whole or not at all. To publish one: `swift Scripts/update-key.swift community-key FILE` once (it prints the
public key and its fingerprint), then `make publish-recipes COMMUNITY=1 RECIPES_DIR=<your YAML> UPDATE_KEY_FILE=FILE
UPDATES_DIR=<your site>` — it compiles, signs, has `doz recipe source verify` accept it, and only then writes
`v1/recipes.json` and `v1/recipes/<serial>/` (never pushed without `PUSH=1`).
