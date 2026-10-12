# Trying agents, and what Dozer supports

`doz try` takes you from nothing to talking to an agent in one command. `doz search` tells you whether Dozer runs
something, and how. Both use the same choices as `doz new`, `doz create` and `doz up`, and `--dry-run` shows what any
of them would make before anything is made.

## Try an agent: `doz try`

```sh
doz try grok                       # Grok Build, from nothing: prepared, made, started and attached
doz try gemini --base python       # any choice option works (here: Gemini CLI on the Python base)
doz try                            # a numbered list of the agents, with your keys and whether each is ready
doz try grok --dry-run             # make nothing: print the plan
doz try grok --rm                  # delete it when you leave, without asking
doz try grok --keep                # keep it running when you leave, without asking
doz try grok -d                    # make and start it, but don't attach (it is kept)
```

A try is a throwaway sandbox with safe defaults:

- **No folder of your Mac** — its `/workspace` is its own (isolated).
- **Locked, plus the agent's own model** — it can talk to its AI model and nothing else. `--permissions standard`
  opens package installs; every other choice option works too.
- **The agent's own base** (Grok Build: Debian; Gemini CLI: Node), and its approval prompts off.
- **Your key for its provider** — the provider's default account.
- **Named `try-<agent>`**, then `try-<agent>-2`, …, and shown as a try in `doz ls`.

**When you have no key yet**, a terminal shows **What you need**, the same card for every agent, made from the agent's
recipe:

1. **Paste a key** (hidden) — kept in your Mac's login keychain; the sandbox only ever gets a placeholder.
2. **A key you keep in 1Password, AWS Secrets Manager or a program** — `op://…`, `aws:arn:…`, or a command; read on
   your Mac when needed, never stored (see [Agents and accounts](09-agents-and-accounts.md)).
3. **Signing in inside the agent** — offered only where that sign-in can work in a sandbox, and labelled: the sign-in
   lives in that sandbox, and deleting the try deletes it. (Grok Build's own sign-in uses hosts Dozer keeps out, so
   it is shown, not offered.)

It also says where to get a key. While you deal with the key, the image is already being prepared.

**When you leave** (the agent exits, or you detach with Ctrl-] twice), it asks:

```
Keep this try? [S]leep / [d]elete / [k]eep running [S]:
```

**Sleep** (Enter) hibernates it: everything is kept on disk and it holds no memory; `doz wake try-grok` (or
`doz attach try-grok`) brings it back where it was.
**Delete** removes it and everything in it. **Keep running** leaves it as it is.

**Off a terminal** (a script, `--json`, `-d`) `doz try` asks nothing and does not attach: it makes and starts the try,
keeps it, and prints how to attach. With no key it stops and says how to add one.

## Is it supported? `doz search`

```sh
doz search grok                          # Grok Build — supported · key: xAI (you have work-xai) · try it: doz try grok
doz search grokk                         # nothing called 'grokk' — did you mean grok?
doz search opencode                      # OpenCode — coming: …
doz search                               # everything: supported, then coming
doz search tag:multi-vendor-models       # agents with a capability
doz search --tag api-key --level any     # every agent, with that tag at any level
doz search grok --base alpine            # is it supported on that base?
doz search grok --details                # what it installs, the hosts it may reach, its keys, what is kept out, tags
doz search grok --json                   # the directory entry, and your key and image state beside it
```

It matches agents (by id, alias, title or publisher), key providers (`xai`, `google`, …) and bases (`alpine`, …).

**Tags** describe capabilities (`multi-vendor-models`, `api-key`, `vendor-sign-in`, `free-tier`, `resume`, `musl`,
`open-source`, `headless`, `gateway:openrouter`, …). Each tag has a level per agent: `documented`, `verified`,
`experimental`, `no` or `unknown`. By default only `documented` and `verified` count; `--level` changes that.

**Exit codes**, for scripts and for agents on your Mac:

| code | meaning |
|---|---|
| 0 | supported (or a plain `doz search`) |
| 8 | supported, but not with what you asked (a base it does not run on) |
| 6 | known, but not in this Dozer: coming, or not possible |
| 2 | nothing by that name (it suggests the closest) |
| 64 | usage |

## One set of choices

`doz new`, `doz create`, `doz up` and `doz try` take the same choice options, named after the keys of
[`doz_project.yaml`](04-projects.md):

| option | what it chooses |
|---|---|
| `--agent`, `--base`, `--dockerfile` | the agent and its base (`--image` is the shorthand for both) |
| `--permissions` | what the agent may do: `standard`, `locked`, `open`, `+web`, `-error-reports`, `site:HOST` (`--allow` is the same) |
| `--network` | `agent`, `locked`, `open`, `bake`, `nat` or `none` |
| `--account`, `--key` | the account, and custom keys beside it |
| `--github`, `--ssh-agent` | GitHub as you, your SSH agent |
| `--workspace`, `--isolated` | a folder of your Mac at `/workspace`, or none |
| `--cpus`, `--memory` | resources |
| `--clipboard`, `--browser-bridge`, `--open-files`, `--tmux`, `--ignore-mode`, `--workspace-view`, `--agent-sudo` | the per-sandbox settings |

`doz new my-app` names the sandbox (`--name` still works). `doz init` takes `--agent`, `--base` and `--dockerfile`
and writes them as the file's own keys.

## See it first: `--dry-run`

```sh
doz new --agent grok --dry-run
doz create my-app --agent gemini --base python --permissions +web --dry-run
doz up my-app --dry-run
doz try grok --dry-run --json
```

The plan has three parts:

- **the command** that makes it, showing only what differs from your defaults;
- **the same choices as `doz_project.yaml`**, so a sandbox you like can become a project;
- **what it can reach**, in plain words, from the same rules the proxy will apply ("Talk to xAI (api.x.ai, 4 API
  paths)", "No package installs (Locked)", "Kept out whatever you choose: …", "No folder of this Mac").

It also says whether the image is ready, which account and key it uses (where the key comes from, never the key),
and anything in the way, with the fix. `--json` gives the same plan as data. Looking never starts the host.
