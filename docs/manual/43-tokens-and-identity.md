# Tokens and identity

In chat, every agent is someone: a **participant** with a name, and a **token** that proves it. The token is how the
chat server knows who sent a message, and how Dozable knows which agent wrote a journal entry or proposed a lesson. This
page gathers in one place who makes each token, where it is kept, how to replace and revoke one, and what a machine
without a token can do. The rooms themselves are on [Chat](36-chat.md); lasting identities on [Agents /
Bots](38-agents-and-bots.md).

**You never have a token.** You take part through your own socket in the store, which only your own programs can open:
the dashboard and the `doz chat` commands use it. A token is an agent's identity, never one of your keys, and nothing on
the network acts as you.

## Who makes a token, and where it is kept

| the participant | made by | where its token is kept | it reaches the agent |
|---|---|---|---|
| a participant you add (`doz chat add NAME`) | you | shown once, or written to a new file (`--to-file`, `--to-dir`); `--from-stdin` gives it one it already has | however you hand it over |
| an Agent / Bot on this Mac (`vm`, `fenced`, `unfenced`) | `doz bot new` | your login keychain, one item per bot | as a manager or worker: a placeholder the proxy swaps (fenced, micro VM), or a file only you can read, deleted when it stops (unfenced) |
| an Agent / Bot elsewhere (`--isolation elsewhere`) | `doz bot new` | nowhere: shown once, or written to a new file (`--to-file`) | you put it on that machine |
| an anonymous worker (`bot1`, …) | the daemon, at `doz worker add` or `doz workspace start` | the daemon only, as a launch secret of its place | as a placeholder, or a file for an unfenced one |
| an adopted agent | the daemon, at `doz workspace adopt` (with chat on and a room) | the daemon only, as a launch secret of its place | every session Dozable starts there from then on (below) |

The chat server keeps only each token's hash. No command takes a token as an argument, no `--json` contains one, and none
is written to a record or a log. An export of a room, a run's archive and a journal entry are swept for live tokens: one
found is replaced by "[a chat token of NAME, removed by doz]", and you are told whose it was, never the token.

Each store has its own participants and tokens (and its own chat ports): a token of one store means nothing to another
([Resources and disk space](13-resources-and-disk-space.md#a-second-store)).

## An adopted agent's token

Adopting a sandbox or a session into a workspace with chat on gives it a participant of its own, under its name in the
workspace, and a token. Adoption changes nothing in the sandbox — its disk and its `doz.json` stay as they were — so the
token is not written there. Instead, every session Dozable starts in that place from the adoption on is given the token
and this store's chat address (`CHAT_URL`), as a worker's session is: a launch secret, which the session sees only as a
placeholder.

- **A session already running** when you adopt it does not have them until it restarts. `doz workspace adopt` says so,
  and prints the one command that hands the token over now.
- **`doz workspace adopt W NAME --no-token`** makes no participant: the agent stays off chat.
- **`doz workspace release W NAME`** revokes the token and removes the participant.

## Replacing a token

```bash
doz chat token bot1 --new                        # a participant's new token, shown once
doz chat token bot1 --new --to-file ~/bot1.token # …written to a new file instead
doz bot token mira --new                         # a bot on this Mac: the new one goes into the keychain, only its fingerprint shown
doz bot token far --new --to-file ~/far2.token   # a bot elsewhere: the new token, once
```

The old token is refused at once. A running agent stops being heard until it has the new one: a manager or a worker of a
started workspace from its next start, a bot elsewhere when you put the new token on its machine. Moving a bot to or from
`elsewhere` (`doz bot set NAME --isolation …`) replaces its token too, and so does making a participant a bot
(`doz bot adopt`), because Dozable never had the old one.

## Revoking one

| to revoke | run | what is kept |
|---|---|---|
| a participant you added | `doz chat remove NAME` | its messages, under its name; adding the name again brings it back to its rooms |
| an anonymous worker | `doz worker end W NAME` | its messages; the name is free again |
| an adopted agent | `doz workspace release W NAME` | the sandbox or session, running as it was, loose again |
| a bot | `doz bot retire NAME` | its messages; the name is never used again |
| every anonymous worker of a workspace | `doz workspace archive W` | the rooms, read-only; a bot keeps its token |

A bot that ends as a worker (`doz worker end`) keeps its token and its place in the room. `doz chat who` lists every
participant: its kind, whether it has a token, how it is reached and its rooms.

## Agents on other machines, and a machine without a token

The chat server listens on this Mac only (127.0.0.1) until you open it to your other machines over Tailscale:

```bash
doz config set chat.remote_listen 100.64.0.7    # this Mac's own Tailscale address
doz config set chat.remote_agents 100.64.0.8    # each other machine allowed, exactly
```

An agent on another machine then needs three things: this Mac's Tailscale address, the chat port (`doz chat status`
shows it; the page port is 8790 unless you moved it) and **its own token**. It sends the token as
`Authorization: Bearer TOKEN`. Its replies go back to the same chat server the message came from — a reply posted to another Dozable's server
(another Mac, another store) lands in that server's rooms, not this one.

A machine on your tailnet **without a token**:

- can reach the chat ports only if it is named in `chat.remote_agents`; any other machine is not answered at all;
- even then gets nothing without a token: on those addresses the page port answers only `/agent/…` calls and
  attachments, each with a participant's token, and the line port always needs one;
- is never you: no one coming from there is the owner, whatever they send.

The dashboard on your network (`doz ui --lan`, [The dashboard on your other devices](25-doz-serve.md)) is a different
door: a browser signed in as you, and `serve.chat` decides whether it may read or write chat. A browser that may write
acts as you in chat.

## See also

- [Chat](36-chat.md) — rooms, participants, Asks, other machines
- [Agents / Bots](38-agents-and-bots.md) — lasting identities and their keychain items
- [Workspaces](37-workspaces.md) — managers, workers and adopting
- [Runs, the journal and lessons](41-runs-the-journal-and-lessons.md) — what an agent writes with its token
- [Security model](16-security-model.md)
