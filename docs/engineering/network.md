# The network: the egress proxy, policies, ports

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

A bare file name is in `Sources/DozableKit/`.

| Path | What |
|---|---|
| `SubnetPool.swift` | automatic vmnet subnets for NAT sandboxes and bakes (free on the Mac, unique in the process) |
| `NetworkPolicy.swift` | `NetworkMode`, `NetworkPolicy` (presets, ordered rules, DNS gating), `EgressRule`, IPv4 CIDR |
| `EgressProxy.swift` | the host proxy (vsock listener; CONNECT / plain HTTP / redirected TCP / DNS; decrypted tunnels via NIOSSL on `EmbeddedChannel`; `TLSUpstream` verified by Security.framework); `Wire` socket plumbing; `DNSMessage` |
| `Credentials.swift` | `CredentialBinding`, `CredentialVault` (secrets in memory, placeholders, the byte-exact head rewrite); `HTTPHead` |
| `SandboxCA.swift`, `HTTPRequestReader.swift`, `ConnectionLog.swift` | the per-sandbox CA + leaves; request/body framing; the metadata-only log |
| `Resources/doznet`, `Guest/doznet/` | the guest half of a proxied network — C source, `build.sh` (the same pinned Zig), `PROVENANCE.md` |
| `Sources/DozableKit/PortForwarding.swift`; `Sources/DozableHost/HostCore+Ports.swift`, `PortSignIn.swift`; `Sources/DozableCLI/PortsCommands.swift`; `WebSource/app/views/sandbox.js` (`portButton`) | 617 web ports (forwards on the Mac's loopback, `doz ports`/`doz open`, the Open buttons); 666 sign-in from Open — a recipe port's `ports@1 sign_in` (an argv starting with the recipe's own program, ≤ 15 s) run by the host op `port-open` as the session's user, the first link it prints to that port opened at the forward through LaunchServices (`MacDefaultApp.openURL`). The link never reaches a log, note, event, the store, an answer, an error or a process argument; `DOZ_TEST_OPEN_URL` records it elided and plays the browser (`DOZ_TEST_SIGNED_IN_CHECK`). `PortSignInTests`, `WebPortOpenTests` |
| `Sources/DozableKit/MacModelServer.swift`; `EgressProxy.macModelPort`/`macRoute`; `Wire.connectTCP(allowLoopback:)`; `components/model-source.js` (`localNodes`) | 660: Claude Code through a gateway or a model server on this Mac — the `local` source (`mac.dozable.internal`, one port per sandbox), the known servers, the loopback refusal; `MacModelServerTests` · 683 M2b: every proxy's strict address guard (`EgressProxy.addressGuard` defaults to `AddressGuard.strict`: never this Mac's own addresses, link-local/metadata or mapped forms, whatever the policy; the named port and the seams pass `allowLoopback`), `SandboxAddressGuardTests` |

| `AddressGuard.swift`, `LoopbackProxyListener.swift`; `Sources/DozableHost/MacFenceNetwork.swift`, `MacFenceDenials.swift`; `deckhold.c` (`--hold-fd`, GETFD) | a FENCED session on this Mac: its own `EgressProxy` on a loopback socket its holder holds for the session's life (the host binds it, passes it as the holder's fd 3, keeps a copy; a later host takes it with GETFD; no host → connections wait in the backlog), a per-session password (Basic, checked by SHA-256 in constant time, never forwarded), a 5 s head deadline, 256 connections at most; the sandboxes' permissions with this Mac's Standard (`AgentPermissions.macBase`); the strict address guard (never this Mac's own addresses, link-local/metadata, mapped forms — whatever the policy); the fence's refusals from `log stream` (kernel lines only, matched on the tag after the message's LAST newline); the update hand-over (the old host drains while holding `host.lock`); `EgressProxy.serveUnwrapped` — plain HTTP for GitHub's hosts on a fenced session's own door (gh's `http_unix_socket`), served as the inside of a decrypted tunnel. Fenced is the default for a new `@mac` session (683 M6) — an UNFENCED one never has a proxy or placeholders (CLAUDE.md's `@mac` rule). `doz net log @mac --session S --fence` prints the refusals seen so far; `--follow` follows connections only, not the fence's refusals |

## Rules that each cost a bug to learn here

- **`lo` needs a global-scope source address** (`lo:doz`, 169.254.255.254/32, set by doznet):
  lo's 127.0.0.1 is host-scoped, so without it an outbound socket gets source 0.0.0.0, its SYN is
  still redirected, and every later segment is dropped — a silent stall, not an error.
- **Never `EmbeddedChannel.writeOutbound` / `.finish()` / `close().wait()` with NIOSSL in the
  pipeline.** `writeOutbound` waits on a write promise NIOSSL completes only after the handshake;
  `finish()` waits on close, which waits for the peer's close_notify. Each hung a proxy thread
  forever. Use `writeAndFlush(_, promise: nil)` and `close(promise: nil)`, then drain.
