# Web ports: opening a sandbox's web page on your Mac

Some tools serve a web page from inside the sandbox: a chat playground, a workflow editor, the dev server of the app
you are building. A **forward** makes such a port reachable in your Mac's browser, at `http://127.0.0.1:PORT/` —
on this Mac only, never on your network.

```sh
doz ports my-app                 # the sandbox's forwarded ports: each one's URL on this Mac and whether it listens
doz ports add my-app 3000        # forward the dev server on port 3000 too (kept until you remove it)
doz open my-app                  # open its first web port in your browser (signed in, when the tool says how)
doz open my-app 3000 --print     # or print the URL
doz ports rm my-app 3000         # stop forwarding it
```

In the dashboard, a sandbox's header has an **Open** button for each web port while the sandbox runs, and its
Overview tab lists every forward with its state.

## Where the ports come from

- **The tool's own.** A tool whose recipe declares a web port gets it forwarded in every sandbox made from it — for
  example AIChat's playground (`aichat --serve`, port 8000, opened at `/playground`). Run the server in a session;
  its Open button works as soon as it listens.
- **Yours.** `doz ports add NAME PORT` forwards any port a program you start listens on — a dev server, a notebook,
  a dashboard. `--title` names its button; `--path` is what `doz open` opens. At most 16 per sandbox.

## Pages that ask you to sign in

Some web pages ask for a sign-in that the tool hands out in the sandbox. OpenCode 2's web app is one: `opencode pair`
prints a link that works once, for five minutes. When a tool's recipe says how to get that link, **Open signs your
browser in for you** — in the dashboard and with `doz open`:

1. Dozable runs the tool's own sign-in command in the sandbox (`opencode pair`), as the sandbox's user.
2. It takes the link the command printed for that port, keeps its path, and opens it at your Mac's port for the
   forward — so it works even when the port on your Mac moved.
3. Your browser lands on the page, signed in.

The link is a one-time secret: Dozable never shows it, logs it, keeps it or sends it anywhere but your browser.
`doz open NAME PORT --print` prints the page's plain address instead (without signing in).

If the sign-in does not work (the command failed, took longer than 15 seconds or printed no link), Dozable says why
and opens the page as it is; you can still sign in by hand, as `doz ports NAME` describes. Open on another device
(through `doz ui --lan`) never signs in: the page is on your Mac.

## When it listens

A forward listens **while the sandbox runs**. When the sandbox stops, sleeps or hibernates, its listeners close at
once; when it starts or wakes again — and after Dozable itself restarts — they come back by themselves. `doz ports`
says `stopped` until then.

The port on your Mac is the sandbox's own when it is free. When another program on your Mac already uses it (or it is
below 1024), Dozable picks a free one, says so (`moved`), and keeps it for next time.

## What a forward can and cannot do

- **This Mac only.** It listens on `127.0.0.1` (and `::1`), never on the network. Other programs on this Mac can reach
  it, as they can any local server — a tool with its own sign-in still asks for it.
- **Inbound only.** It carries your browser's requests to the program in the sandbox. It does not let the sandbox
  reach anything: what the program itself may reach is still decided by the sandbox's [network](10-permissions-and-network.md).
- **No key crosses it.** Your keys are swapped in by Dozable's proxy only on the sandbox's own outbound requests; a
  forward never touches them. A page that shows its environment shows a placeholder, which is useless anywhere else.
- **From another device** (the dashboard through [`doz ui --lan`](25-doz-serve.md)), `127.0.0.1` is that device, not your
  Mac: the button says the port is on the Mac instead of opening it there.

How it works: each connection your browser makes is relayed into the sandbox by Dozable's small helper there, to the
program's own `localhost`. A program that listens on `127.0.0.1` or `0.0.0.0` inside the sandbox both work.
