# Claude Code with other models — a gateway, or a model server on your Mac

Claude Code talks to Anthropic by default: this Mac's Claude login, a setup token or an Anthropic API key, exactly as
in [Agents and accounts](09-agents-and-accounts.md). It can also get its model from:

- **a gateway** — OpenRouter: one key, models from many makers, through the gateway's Anthropic-compatible endpoint;
- **a model server on this Mac** — Ollama, LM Studio, llama.cpp's `llama-server`, LiteLLM, vLLM or oMLX, reached by
  its port. No key.

Anthropic supports Claude models only. Another maker's model through a gateway or your own server is yours to judge —
it may not handle Claude Code's tools as well.

## Through a gateway (OpenRouter)

Add the gateway's key once — it stays in this Mac's keychain, like every key:

```
doz account add my-or --provider openrouter
```

Then try Claude Code through it, with a model by the gateway's name for it:

```
doz try claude-code --gateway openrouter --model anthropic/claude-sonnet-4.6
```

`doz models --gateway openrouter` lists the gateway's models. The sandbox gets the gateway's address and a
placeholder in `ANTHROPIC_AUTH_TOKEN`; Dozable's proxy on the Mac swaps in the real key, and only on the way to
openrouter.ai. A placeholder sent anywhere else is refused. A Claude subscription is never used this way: the
gateway key replaces it.

## A model server on your Mac

Start the server on your Mac first (`ollama serve`, LM Studio's server, …), then:

```
doz try claude-code --provider local --local-port 11434 --model qwen3-coder
```

- `--local-port` is the port the server listens on (Ollama 11434, LM Studio 1234, llama-server 8080, LiteLLM 4000,
  vLLM and oMLX 8000).
- `--model` is the server's own name for the model (`ollama list`, LM Studio's list). Every alias Claude Code uses
  (and its subagents) gets that model, so it never asks your server for a Claude model it does not have.
- There is no key: Claude Code is given a fixed word in `ANTHROPIC_AUTH_TOKEN`, which the local servers ignore.

`doz models --provider local` lists the servers known to work, with the port each uses by default.

The servers must speak **Anthropic's Messages API** (`/v1/messages`) — Ollama (0.14 or later), LM Studio (0.4.1 or
later), llama-server, LiteLLM, vLLM and oMLX do. A server that speaks only OpenAI's chat API (`mlx_lm.server`) needs
a translator in between: not yet.

In a project file:

```yaml
model_source: local
local_port: 11434
model: qwen3-coder
```

### What the sandbox can reach on your Mac

A sandbox has no network of its own: everything it sends goes through Dozable's proxy, which runs on your Mac. So:

- **One name, one port.** The sandbox reaches your server as `http://mac.dozable.internal:PORT`, for the port it was
  made with — the proxy sends that to `127.0.0.1:PORT` on your Mac. Any other port of that name is refused, and a
  sandbox made without a port cannot resolve the name at all.
- **Nothing else on your Mac's localhost.** `127.0.0.1`, `localhost` and `::1` through the proxy are refused for
  every sandbox, whatever its network — Open included. (Inside the sandbox, `localhost` is the sandbox's own.)
- It is not a network permission: no preset or edit widens it. The sandbox's Network tab says it ("This Mac: port
  11434 only"), and so does the agent's own description of its sandbox.
- `doz doctor` checks that something answers on each such port.

The port is chosen when the sandbox is made; for another port, make another sandbox.

## In the dashboard

Try (Claude Code's setup) and New sandbox (its Account step) show **Where Claude Code gets its model**: Anthropic
with its usual account choice, OpenRouter with its key, and **A model server on this Mac** with a port (one click
for the known servers) and the model. The sandbox's page shows where its model comes from ("via OpenRouter · model
…", "via this Mac's port 11434 · model …"). Accounts & keys says a server on your Mac needs no key.
