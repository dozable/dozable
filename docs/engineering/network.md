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
| `Sources/DozableKit/MacModelServer.swift`; `EgressProxy.macModelPort`/`macRoute`; `Wire.connectTCP(allowLoopback:)`; `components/model-source.js` (`localNodes`) | 660: Claude Code through a gateway or a model server on this Mac — the `local` source (`mac.dozable.internal`, one port per sandbox), the known servers, the loopback refusal; `MacModelServerTests` |

## Rules that each cost a bug to learn here

- **`lo` needs a global-scope source address** (`lo:doz`, 169.254.255.254/32, set by doznet):
  lo's 127.0.0.1 is host-scoped, so without it an outbound socket gets source 0.0.0.0, its SYN is
  still redirected, and every later segment is dropped — a silent stall, not an error.
- **Never `EmbeddedChannel.writeOutbound` / `.finish()` / `close().wait()` with NIOSSL in the
  pipeline.** `writeOutbound` waits on a write promise NIOSSL completes only after the handshake;
  `finish()` waits on close, which waits for the peer's close_notify. Each hung a proxy thread
  forever. Use `writeAndFlush(_, promise: nil)` and `close(promise: nil)`, then drain.
