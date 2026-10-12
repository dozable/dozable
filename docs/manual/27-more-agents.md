# More agents: Antigravity CLI, Grok Build, Gemini CLI

Beside Claude Code, pi and Codex, Dozer runs three agents from other makers. Each uses an **API key** of its
maker's; the key stays on your Mac and the sandbox only ever gets a placeholder, which Dozer's proxy swaps for the key
on the way out — and only to that maker's own API.

```sh
doz try antigravity      # Google's agent (alias: agy)
doz try grok             # xAI's agent
doz try gemini           # Google's earlier agent (superseded by Antigravity CLI)
doz search google        # what Dozer runs with a Google key, each with its latest release
```

The first `doz try` of each asks for the key (a paste, or where you keep it: 1Password, AWS, a command — see
[Keys from 1Password, AWS or a command](09-agents-and-accounts.md#keys-from-1password-aws-or-a-command)), prepares the
agent's image once (a minute or so) and starts it. A try is Locked: the agent reaches its model and, below, the few
hosts its maker's program calls when it starts — nothing else. [Trying agents](26-try-and-search.md) has the rest.

## Antigravity CLI (Google)

Google's terminal agent and **the one to use with a Google key** (`doz try antigravity`, or `agy`).

- **Installed** from Google's own release for linux-arm64, checked against the SHA-512 Google publishes with it.
  Debian-based bases only for now (not Alpine). It is closed source; Dozer installs it from Google, it does not
  redistribute it.
- **Key:** a Gemini API key (`doz account add google --provider google`; get one at https://aistudio.google.com/apikey).
  Dozer never offers the Google sign-in: it keeps its token in a keyring inside the machine.
- **Set up for you:** approval prompts off (`antigravity.permissions = ask` keeps them), its updater off, its
  telemetry setting off.
- **May reach:** the Gemini API (its model); Google's feature switches for it (`antigravity-unleash.goog`) when it
  starts.
- **Kept out quietly:** its usage log to `play.googleapis.com`, every few seconds. Its own telemetry setting does not
  stop it, so Dozer refuses it — logged in `doz net log`, never counted as a refusal (a fresh try shows none).

## Grok Build (xAI)

- **Installed** from the npm registry's linux-arm64 package, integrity-checked. Debian, Node and Alpine bases.
- **Key:** an xAI API key (`doz account add xai --provider xai`).
- **Set up for you:** approval prompts off, its auto-updater off, its telemetry and feedback off; copying to your
  Mac's clipboard works (Dozer tells it the terminal takes OSC 52).
- **May reach:** xAI's API (the paths Grok Build uses, and its key-less start-up check of `api.x.ai/`), and its release
  notes on `x.ai` when it starts.
- **Kept out, whatever you choose:** xAI's sign-in hosts (Dozer never offers the sign-in).

## Gemini CLI (Google) — superseded

Superseded by Antigravity CLI: Google retired Gemini CLI for personal accounts; it still works with a **paid** Gemini
API key. Dozer keeps it, listed after the current agents; `doz try gemini` says so first.

- **Installed** from the npm registry, integrity-checked. Node, Debian and Alpine (on Alpine its shell tool runs
  without a terminal).
- **Key:** a Gemini API key, as Antigravity CLI. Never the Google sign-in (Google's terms forbid third-party tools from
  using it).
- **Set up for you:** approval prompts off, usage statistics off, auto-update off.

## What each one calls — the network profiles

Dozer keeps a **network profile** of every agent: a fresh try with the network open and every request logged, its
first start and a short task, and for each host and path it called, a decision — allowed (and why), allowed by its
path only, turned off by the agent's own setting, or refused. The recipes are checked against these profiles on every
build, so an agent never meets a refusal on a normal first run, and a new release is profiled again before anything
new is allowed (`make profile-agents` in the source tree; `make agent-currency` says which agents moved).

## Is it current?

`doz search`, `doz try` and the Quick try show each agent's **latest release** as your Mac last saw it — the version,
the day it came out, how long ago, and **active** (a release in the last 3 months), **quiet** (none for 3),
**stale** (none for 6) or **deprecated** by its maker — and its **standing**: current, or superseded by another
agent. See [Is it current?](26-try-and-search.md#is-it-supported-doz-search).
