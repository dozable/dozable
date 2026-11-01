# The LAN option

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableWeb/WebServe*.swift`, `WebExposure.swift`, `WebQR.swift`, `WebBonjour.swift`; `Sources/DozableCLI/ServeCommand.swift`; `Sources/DozableKit/LocalDashboards.swift` | `doz ui`'s LAN option (645; `doz serve` before) — the rules (`WebServe`: addresses, the accept gate, the request's own origin, `isMacRequest`, `WebDashboardPort`), devices + invites (`WebServeDevices`), the audit log, `serve.sock` (`WebServeControl`), the server's LAN side (`WebServeServer`, `WebServeState`, `WebAuth`), the capability table, our QR encoder, Bonjour; the CLI (`LANDashboard`, `doz ui share|devices|revoke|rename|log|status`, the hidden `doz serve` alias, doctor's public-origin check); the egress proxy's refusal of the dashboards' ports |

## The LAN option (`doz ui --lan`) — the dashboard for the other browsers of the network

606 shipped this as `doz serve`, a second process; 645 (owner: one dashboard command) made it `doz ui`'s LAN option.
`doz serve` is a HIDDEN alias for one release (`ServeCommand`: `doz serve` = `doz ui start --lan` with a note on stderr;
its subcommands still parse) — remove it in a later release, saying so.

- **One process, one port**. The LAN option (`ui.lan`, default off, `ui: false` — never set from a browser; `--lan` /
  `--no-lan`, `--bind`, `--no-invite`) makes `UIRunner` call `LANDashboard.bind` (`ServeCommand.swift`): it takes
  `<store>/serve.lock` as well as `ui.lock` (an earlier `doz serve` still running holds it → refused, naming
  `doz serve stop`), builds `WebServeState` + `DozableWebServer.bindServe` with the Mac's session files, writes
  `<store>/serve/port`, answers `serve.sock` (one line in, one JSON line out: status, devices, share, revoke, rename,
  probe, stop — `WebServeControl`; `stop` stops the whole dashboard) besides `ui.sock`, and announces with Bonjour. It
  keeps `<store>/serve/` (0700: `devices.json`, `audit.jsonl`, `port` — 0600) where `doz serve` kept it: an earlier
  store's devices are read as they are (the migration is reading the old files). Without the LAN option the Devices
  page reads those files (or asks an earlier `doz serve` over `serve.sock`).
- **Detached / at login**: `doz ui --lan --detach` is ui's own double spawn (`DetachedLauncher.ui*Args`, `<store>/ui.log`;
  the flags passed on); afterwards the CLI prints the LAN addresses + an invite (a TTY only). `doz ui status` carries
  pid, since, version, detached, log, responsibleApp (the app macOS attributes it to — it survives the double spawn, as
  604 found for the microphone; Bonjour's Local Network ask is on its behalf). No start-at-login (no launchd agent —
  the host's rule; an opt-in `doz ui login` is the owner's call).
- **Loopback is served under every bind**: this Mac's own browser at `127.0.0.1:<port>` is the Mac principal
  (`isMacRequest`, above); [::1], localhost and `<mac>.local` from the Mac are devices like any other (rc.1 bug: on the
  Mac, `<mac>.local` resolved to ::1 and the silent drop read as "no response"). **Only a sandbox's connection is
  dropped silently**; any other refusal (an address not served, the per-address cap) is answered over HTTP
  (`refusedConnections` → `refuse`). Invites print their LAN-address forms beside `.local`
  (`WebServeInviteAnswer.alternates`, also for the Mac's own page's Add another browser).
- **Where it listens** (`serve.bind`): `lan` = the wildcard `[::]` (dual-stack: 127.0.0.1 included) with an accept gate on
  each connection's LOCAL address (`WebServeRules.isServed`: `en*`, `bridge0–99`, the `utun` holding a Tailscale address;
  a LAN interface's link-local too — m1a reached `<mac>.local` over fe80::), re-read every 3 s; `loopback` (127.0.0.1 +
  ::1, a proxy on this Mac); or the Mac's addresses (+ 127.0.0.1). The port (`ui.port`, else `serve.port` 7443) never
  moves: taken → refused, naming the holder.
- **Sandboxes NEVER reach it** (non-negotiable; `nat-source.md` measured that a NAT guest arrives with its OWN address):
  a peer in a vmnet bridge's (`bridge100`+) networks, Dozable's automatic NAT range 192.168.100–199.0/24 where no LAN
  interface is, or `defaults.nat_subnet` is dropped before a byte is read, and so is a connection to a bridge's own
  address. A bridge's link-local prefix is NOT a sandbox network (fe80::/64 is every interface's). Proxied sandboxes
  have no NIC — their traffic leaves from the host: `LocalDashboards` (DozableKit) makes `Wire.connectTCP` refuse the
  Mac's own addresses on the dashboards' ports (`<store>/ui.port`, `<store>/serve/port`, `serve.port`; the host sets
  it, 5 s cache) whatever the policy, `open` included. `probes/606-*/serve-sandbox.mjs` (NAT + proxied-open, with
  positive controls) is the test.
- **Admission**: an invite = a 256-bit link token (`#cap=`, posted as Bearer — the doz ui model) + an 8-char Crockford
  code (`{"code"}` on `POST /api/v1/session`) + the QR of the link; first use wins and kills the rest; 5 minutes; ≤ 8
  open. Wrong attempts: 10 per address / 10 min → 429; 20 wrong codes in all cancel every open code. A device's cookie
  is never stored (digest + CSRF only); its 401s say `not-admitted` / `device-revoked`; revoke ends its streams
  (`end: revoked`) and terminals (1008) at once. The cookie's Max-Age is 400 days, re-set at every renewal.
- **The request's own origin** (`WebServeRules.requestOrigin`, pure): `http://<Host>` when Host is one of the Mac's names
  (`<LocalHostName>.local`, gethostname) or served address literals (never link-local); else, ONLY from a
  `serve.trusted_proxies` peer, `X-Forwarded-Proto` (ws/wss count as http/https — Traefik sends wss on upgrades) +
  `X-Forwarded-Host` naming a `serve.public_origins` entry. `Origin` must EQUAL it. Over https: `__Host-doz_serve_<port>`
  + Secure; else `doz_serve_<port>`. A trusted proxy is exempt from the per-address connection cap (32): every browser
  behind it shares its address (an HTTP/2 page's module burst starved through Caddy before that fix).
- **`WebExposure`** — the closed table (a `switch` with no `default`; `ServeExposureTests` pins every route), applied to
  each request's OWN principal (so the Mac's browser on the LAN dashboard keeps everything): remote may do everything
  except `secretEntry` over plain HTTP (403 `secret-over-http`; the page shows the reason instead of the field —
  `secretEntryAllowed()`) and `macScreen` (pickers, Open in Terminal: 403 `mac-screen`; hidden by `isRemote()`).
  `ui.lan` and the `serve.*` settings are `ui: false`. A new route needs a decision there.
- **The page**: `state.serve` (from `sessionInfo.serve`), `core/session.js`'s serve sign-in (code or pasted link — the
  router's `#cap=` hand-off still works), `views/devices.js`, `components/share.js` + `components/qr.js` (the server
  sends the QR matrix as rows; SVG by createElementNS; `--qr-light/--qr-dark` tokens). An http page is not a secure
  context: guard `navigator.clipboard` (no service worker there either — `registerWorker` already checks).
- **The audit log** (`WebServeAudit`): admissions, shares, revokes, renames, every unsafe remote request (route, action,
  sandbox, outcome), terminal open/close, refusals, drops — collapsed per minute for the noisy kinds; never a body,
  cookie, token, code or header value. Rotated at 1 MiB × 3. `doz ui log`. Only REMOTE requests are audited (the
  Mac's own browser never was).
- **Doctor**: `ServeDoctor` fetches each public origin's `/api/v1/serve/probe` with a one-use token (serve.sock `probe`);
  `DOZ_TEST_SERVE_CA` (tests) trusts only a scratch CA. Bonjour failures are said, never fatal.
- **Tests**: `ServeQRTests` (ISO vectors + CoreImage round trips), `ServeRulesTests` (incl. `isMacRequest`, the one
  port), `ServeDevicesTests`, `ServeExposureTests`, `ServeHTTPTests` (645: the Mac by the link and a device by an invite
  on one port, per-request abilities, a forwarded request never the Mac, a sandbox dropped even with the Mac's Host,
  rotate keeps devices), `LocalDashboardsTests`, `CommandTests` (`--lan`, the alias); probes `probes/645-*/` (one
  `doz ui --lan`: the Mac's Chrome + a device, restart, the alias) and `probes/606-*/` — `serve-lan.mjs` (two Chrome
  devices on the LAN address), `serve-proxy.mjs` (Caddy + Traefik, a scratch CA, doctor), `serve-sandbox.mjs`,
  `serve-m1a.mjs` (curl + m1a's own Chrome over an ssh-tunnelled DevTools port). Probes use ports 17606–17609, never 7443.
