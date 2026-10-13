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
