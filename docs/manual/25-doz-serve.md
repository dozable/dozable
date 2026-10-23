# The dashboard on your other computers, tablets and phones (`doz ui --lan`)

`doz ui` is one dashboard. Without its LAN option it listens on `127.0.0.1` and nothing but this Mac can reach it.
With the LAN option the SAME dashboard, on the same port, also serves the other browsers of your home network — the
laptop on the couch, a second Mac, the iPad, a phone — at `http://<this Mac>.local:7443`.

```bash
doz ui --lan                          # this run
doz config set ui.lan true            # every run (then: doz ui restart, if one is running)
```

Nothing listens beyond this Mac until you turn it on, and it is only ever turned on here, on the Mac (`ui.lan` cannot
be changed from a browser). It runs until you press Ctrl-C (or run `doz ui stop` in another terminal). To keep it
running without a terminal open, start it in the background:

```bash
doz ui --lan --detach        # or -d: prints where it listens and an invite, then returns
doz ui status                # pid, since when, the addresses, the version, its log
doz ui stop
```

A detached `doz ui` belongs to no terminal — closing the terminal does not stop it; its output goes to
`<store>/ui.log`.

The earlier name of `doz ui --lan`, doz serve, still works for one release (it says so), and so do its subcommands
(share, devices, revoke, rename, status, log and stop).

## This Mac's browser and the others

**This Mac's browser** is signed in by the link `doz ui` opens (or `doz ui link`), at `http://127.0.0.1:<port>`, as
without the LAN option — and it can do everything, including typing a key and the windows on the Mac's screen (the
folder pickers, Open in Terminal).

**Every other browser** gets in once, with an **invite**, and then stays in until you remove it. An invite is three
things at once — use whichever suits the device:

- a **QR code** — point a phone's or tablet's camera at it;
- a short **access code** like `Y14G-99K3` — type it on the dashboard's sign-in page;
- a **link** — open it in the other browser.

Whichever is used first lets ONE browser in, within five minutes; the other two stop working. `doz ui --lan` prints an
invite when it starts (on a terminal) — its link by name (`http://<this Mac>.local:7443/…`) and by each of the Mac's
addresses (`http://192.168.1.20:7443/…`): `.local` names do not resolve the same everywhere, so use an address if the
name does not answer. For another invite:

```bash
doz ui share
```

or, on any browser that is already in (this Mac's too): **Devices › Add another browser**.

Which kind of browser a request comes from is decided for each request: only a connection from this Mac itself, to
`127.0.0.1:<port>` exactly, with no reverse proxy in between, is this Mac's browser. The same Mac reaching the
dashboard by `<this Mac>.local` or `localhost` is treated like any other browser (it needs an invite).

A browser that opens the dashboard without an invite sees the sign-in page and nothing else — no sandbox, no name, no
data. A request the dashboard refuses always gets an answer saying why — only a sandbox's connection is dropped
without one.

## What another browser can do

Everything the Mac's browser does — watch and drive sandboxes, open terminals in the browser, create sandboxes,
change their network, settings, images and resources — with two exceptions:

- **No keys or tokens over plain HTTP.** Adding an account's API key or setup token, a sandbox's own key or a GitHub
  token would send it across your network unencrypted, so the dashboard does not offer the field there and refuses
  it. Add it on the Mac (`doz account add NAME --api-key`, or this Mac's own browser), or reach the dashboard over
  HTTPS through your reverse proxy (below) — there it is allowed.
- **Nothing that opens a window on the Mac's screen**: the Mac's folder and file pickers, **Open in Terminal**, **Open folder** and the Files tab's Open items are
  not shown on another computer. Type the folder's path instead, and use the browser's own terminals.

`ui.lan` and the `serve.*` settings — who can reach the dashboard — are changed only on the Mac, with `doz config set`.

## The browsers that are in

```bash
doz ui devices              # name, when let in, last seen, from where, which browser
doz ui rename ID "Kitchen iPad"
doz ui revoke ID            # or --all
```

The **Devices** page (on every browser that is in, and on this Mac's) lists the same, with **Remove** and **Rename**,
and the recent activity. A removed browser is signed out at once — its pages say so and its terminals close — and
needs a new invite to come back. A new link for this Mac's browser (`doz ui link --rotate`, `doz ui --new-link`) signs
out this Mac's pages only; the other browsers stay in.

Every change another browser asks for, every terminal it opens, every admission and every refusal is written to an
audit log — never a key, a code or what was typed:

```bash
doz ui log
```

## Where it listens

By default (`serve.bind = lan`) on every network interface of this Mac (Wi-Fi, Ethernet, the Thunderbolt Bridge) and
on Tailscale — never on a sandbox's network. A sandbox can never reach the dashboard: a connection from a sandbox's
network is dropped before anything is read, and the proxy that carries a proxied sandbox's traffic refuses the Mac's
own addresses on the dashboard's port, whatever the sandbox's network policy says. This Mac's own browser is served
at `127.0.0.1` whatever `serve.bind` says.

With the LAN option the dashboard announces itself with Bonjour as "Dozable on <this Mac>" (`serve.advertise`), so
Safari's Bonjour list and other devices can find it.

The port is the dashboard's one port, `ui.port`. While `ui.port` is 0 (automatic), the LAN option uses `serve.port`
(7443): with other browsers it never moves by itself — their sign-ins, an installed app and a bookmark belong to it.
When another program holds it, `doz ui` refuses and names that program.

```bash
doz config set ui.port 8443
```

## HTTPS behind your own reverse proxy

If you already run a reverse proxy at home (Caddy, Traefik, nginx, Nginx Proxy Manager, a Cloudflare Tunnel …), put
the dashboard behind it: your proxy does HTTPS, and through it the dashboard can be installed as an app (with its
offline page) and takes keys and tokens.

Tell `doz ui` three things:

```bash
doz config set serve.public_origins https://doz.home.example   # the address your proxy serves it at
doz config set serve.trusted_proxies 127.0.0.1,::1             # your proxy's address (here: on this Mac)
doz config set serve.bind loopback                             # a proxy on this Mac: listen on 127.0.0.1 only
```

For a proxy on another machine of your network, set `serve.trusted_proxies` to that machine's address and
`serve.bind` to this Mac's address the proxy connects to (or leave it `lan`).

The dashboard believes `X-Forwarded-Proto`, `X-Forwarded-Host` and `X-Forwarded-For` ONLY from the addresses in
`serve.trusted_proxies`; from anyone else they are ignored, and the public address is refused. A request that came
through a proxy is never treated as this Mac's own browser, even from a proxy on this Mac. When it starts it prints
the upstream your proxy should use and what is missing. Check the whole path:

```bash
doz doctor
```

— its `dashboard via https://…` line fetches each public address from this Mac and says whether it came back to this
dashboard, over https, through a trusted proxy.

What your proxy must do: pass the `Host` header (or `X-Forwarded-Host`), set `X-Forwarded-Proto` and
`X-Forwarded-For`, pass WebSocket upgrades (the terminals), and not buffer responses (the live updates are a
server-sent event stream).

### Caddy

```caddyfile
doz.home.example {
	reverse_proxy 127.0.0.1:7443 {
		flush_interval -1
	}
}
```

Caddy passes `Host`, sets the forwarded headers and upgrades WebSockets by itself; `flush_interval -1` keeps the live
updates unbuffered.

### Traefik (file provider)

```yaml
http:
  routers:
    doz:
      rule: "Host(`doz.home.example`)"
      entryPoints: [websecure]
      service: doz
      tls: {}
  services:
    doz:
      loadBalancer:
        servers:
          - url: "http://127.0.0.1:7443"
```

Traefik passes `Host` and the forwarded headers and upgrades WebSockets by default.

### nginx (and Nginx Proxy Manager's custom configuration)

```nginx
map $http_upgrade $connection_upgrade { default upgrade; '' close; }

server {
    listen 443 ssl;
    server_name doz.home.example;
    ssl_certificate     /etc/ssl/doz.home.example.pem;
    ssl_certificate_key /etc/ssl/doz.home.example.key;

    location / {
        proxy_pass http://127.0.0.1:7443;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_buffering off;
        proxy_read_timeout 1h;
    }
}
```

`proxy_buffering off` matters: with nginx's default buffering the live updates arrive late or not at all.

### Cloudflare Tunnel

```yaml
# ~/.cloudflared/config.yml
tunnel: <your tunnel id>
credentials-file: /Users/you/.cloudflared/<your tunnel id>.json
ingress:
  - hostname: doz.example.com
    service: http://127.0.0.1:7443
  - service: http_status:404
```

`cloudflared` runs on this Mac, so `serve.trusted_proxies` is `127.0.0.1,::1` and `serve.public_origins` is
`https://doz.example.com`. A tunnel puts the dashboard on the Internet: put Cloudflare Access in front of it too.

The Caddy and Traefik configurations above are the ones Dozable's own tests ran in front of the dashboard (terminals,
live updates, the installable app, keys over https, `doz doctor`); the nginx and Cloudflare ones follow the same rules.

## The macOS firewall and Local Network privacy

- **Firewall** (System Settings › Network › Firewall): when it is on, macOS asks once whether `doz` may accept incoming
  connections — answer **Allow**. A `doz` installed with Homebrew is signed, and with the firewall's "Automatically
  allow downloaded signed software" (on by default) it is allowed without asking. With "Block all incoming
  connections" nothing on your network can reach the dashboard; `doz ui --lan` says so when it starts. It never
  changes your firewall's settings.
- **Local Network privacy**: accepting connections from your network needs no permission. Announcing with Bonjour is
  done on behalf of the app you run `doz ui` in (Terminal, iTerm2, your editor); if macOS has refused that app Local
  Network access, `doz ui` says it was not announced — browsers still reach it by address and by `<this Mac>.local`.
  To announce it: System Settings › Privacy & Security › Local Network, allow that app, or set `serve.advertise` to
  false.

## Settings

| setting | default | what |
|---|---|---|
| `ui.lan` | false | serve your other browsers too (`--lan`, `--no-lan`, `$DOZ_UI_LAN`) |
| `ui.port` | 0 | the dashboard's one port; 0 = automatic (`--port`, `$DOZ_UI_PORT`) |
| `serve.port` | 7443 | the port with the LAN option while `ui.port` is 0 (`$DOZ_SERVE_PORT`) |
| `serve.bind` | `lan` | `lan`, `loopback`, or this Mac's addresses (`--bind`, `$DOZ_SERVE_BIND`) |
| `serve.public_origins` | — | your proxy's https addresses |
| `serve.trusted_proxies` | — | your proxy's addresses or networks |
| `serve.advertise` | true | announce with Bonjour |

All of them apply when `doz ui` starts again (`doz ui restart`). See the [Settings reference](15-settings-reference.md).
