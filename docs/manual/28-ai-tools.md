# Other AI tools

Beside the coding agents, Dozer runs AI tools that are not coding agents: command-line tools that answer a prompt,
prompt toolkits, agent frameworks. Each is tried like an agent (`doz try TOOL`) and uses an **API key** of a provider
Dozer offers. The key stays on your Mac; the sandbox only gets a placeholder, which Dozer's proxy swaps for the key on
the way out, and only to that provider's own API.

```sh
doz try fabric           # Fabric, on a Gemini API key
doz search gemini        # what Dozer runs with a Google key
```

A tool that answers and exits opens a **shell** as its session, with the tool on the PATH. Type its commands there.

## OpenClaw

A self-hosted personal agent with shell and file tools. Its own docs recommend running it isolated: in a sandbox its
tools act on the sandbox, not your Mac.

- **Installed** from the npm registry, integrity-checked, on Node 24, which Dozer installs for it (Debian-based bases
  only). The image is large (about 1.3 GB).
- **Key:** a Gemini API key, as Fabric below.
- **Use:** one headless turn — `openclaw agent exec "a task" --auth-env-only --model google/gemini-2.5-flash`. Its
  auto-update is off (`OPENCLAW_NO_AUTO_UPDATE`).
- **May reach:** the Gemini API.
- **Later:** its Gateway (the TUI, the Control UI on port 18789, chat channels such as Telegram or Slack) is a
  background service with a web page, which Dozer does not run or forward yet. You can start it by hand in a second
  session (`openclaw gateway`), but nothing keeps it running and the Control UI is not reachable from the Mac.

## nanobot

A small personal agent in the terminal (an OpenClaw-style assistant its authors keep auditable).

- **Installed** from PyPI with every dependency pinned by its hash, on Dozer's own Python (Debian-based bases).
- **Key:** an xAI API key (`doz account add xai --provider xai`). nanobot is set up with its custom OpenAI-compatible
  provider pointed at xAI's API and the model `grok-4-1-fast` (`~/.nanobot/config.json`, keys written only when not there
  yet — change the model there).
- **Use:** `nanobot` opens its terminal UI (the session); one headless turn is `nanobot agent -m "a task"`.
- **May reach:** xAI's API, and OpenAI's public tokenizer file (`openaipublic.blob.core.windows.net/encodings/…`), which
  the token counter it uses downloads at the first turn.
- **Later:** its gateway (chat channels) and web UI need a background service and a forwarded port.

## gptme

A terminal agent with shell, Python and file tools.

- **Installed** from PyPI with every dependency pinned by its hash, on Dozer's own Python (Debian-based bases).
- **Key:** an xAI API key; gptme finds `XAI_API_KEY` and picks its xAI model itself (or `--model xai/MODEL`).
- **Set up for you:** its confirmation prompts off (`--no-confirm`; `gptme.permissions = ask` keeps them).
- **Use:** `gptme` (the session); one headless run is `gptme --non-interactive "a task"`.
- **May reach:** xAI's API, and OpenAI's public tokenizer file (as nanobot).
- **Later:** its browser tool needs Chromium in the image; `gptme-server`'s web UI needs a forwarded port.

## llm

Simon Willison's command-line tool for prompting models (and logging every prompt to SQLite).

- **Installed** from PyPI with every dependency pinned by its hash, on Dozer's own Python (Debian-based bases), with the
  `llm-grok` plugin, which talks to xAI.
- **Key:** an xAI API key (`XAI_API_KEY`, read by the plugin).
- **Use:** the session is a shell. `llm -m grok-4-1-fast "a question"`; `llm models default grok-4-1-fast` once makes
  that the default (without it llm asks OpenAI, which Dozer does not offer it).
- **May reach:** xAI's API.
- **Later:** `llm install` (more plugins) needs PyPI at run time, which no permission offers yet.

## ShellGPT

A command-line assistant (`sgpt`) that answers questions and turns requests into shell commands (`sgpt --shell`).

- **Installed** from PyPI with every dependency pinned by its hash, on Dozer's own Python (Debian-based bases).
- **Key:** an xAI API key. ShellGPT speaks OpenAI's API; Dozer points it at xAI's (`API_BASE_URL`) and gives it the
  key's placeholder under `OPENAI_API_KEY` too — the placeholder still works only on xAI's API. The model is
  `grok-4-1-fast` (`DEFAULT_MODEL`, or `--model`).
- **Use:** the session is a shell. `sgpt "a question"`, `sgpt --shell "find large files"`.
- **May reach:** xAI's API.

## ZeroClaw

A personal-agent runtime in one Rust program, with shell, file and web tools.

- **Installed** from the project's linux-arm64 release on GitHub, checked against the SHA-512 Dozer recorded (Debian-based
  bases).
- **Key:** an xAI API key. ZeroClaw is set up (`~/.zeroclaw/config.toml`, keys written only when not there yet) with one
  OpenAI-shaped provider pointed at xAI's API, the model `grok-4-1-fast`, and one agent, `main`, at full autonomy — the
  sandbox is the boundary. The key's placeholder reaches it through ZeroClaw's own environment override.
- **Use:** the session is `zeroclaw agent -a main`; one headless turn is `zeroclaw agent -a main -m "a task"`.
- **May reach:** xAI's API.
- **Later:** its gateway, web dashboard and chat channels need a background service and a forwarded port.

## Fabric

A prompt toolkit: crowd-sourced "patterns" applied to text you pipe in.

- **Installed** from the project's own linux-arm64 release on GitHub, checked against the SHA-512 Dozer recorded when it
  pinned the release. Debian, Node and Alpine bases.
- **Key:** a Gemini API key (`doz account add google --provider google`; get one at https://aistudio.google.com/apikey).
  Fabric is set up with Gemini as its default vendor (`DEFAULT_VENDOR` and `DEFAULT_MODEL` in
  `~/.config/fabric/.env`, written only when not there yet).
- **Use:** `echo "some text" | fabric "summarise this"`, or `fabric -U` once to download the patterns (from GitHub:
  allow "Use GitHub" in the sandbox's network), then `cat notes.txt | fabric -p summarize`.
- **May reach:** the Gemini API.
- **Later:** `fabric --serve` (its REST API and web UI) needs a port forwarded to the Mac, which Dozer does not offer yet.
