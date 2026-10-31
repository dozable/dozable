# How the recipe catalogue is signed

Dozable's recipes can arrive after a release: the **recipe catalogue** is published at `https://doz.sh/v1/recipes.json`
and every running doz host looks for a newer one about once an hour. This page explains why that catalogue is signed,
how the key is used, and what is (and is not) protected. The format itself is in
[`recipes/RECIPE-FORMAT.md`](recipes/RECIPE-FORMAT.md); the code is `Sources/DozableKit/RecipeCatalogue.swift` and
`Sources/DozableHost/RecipeCatalogueClient.swift`.

## Why it is signed

A recipe is powerful. It tells doz:

- what to download and install into a sandbox, and the checksum it must match;
- which sites the sandbox may reach;
- for each model provider (Anthropic, OpenAI, OpenRouter …), which addresses your API key is sent to.

The catalogue comes over the internet and is picked up with no one watching. Anyone who could change it — at the host
(GitHub Pages), the CDN in front of it (Cloudflare), the domain's registrar, or whoever held doz.sh if it ever lapsed —
could make a sandbox install their software, open its network, or send your key to their own server. HTTPS protects
only the connection; it does not prove who wrote the file.

The signature does. It lets every doz check that a catalogue came from Dozable's publisher and that nothing in it was
changed. The security rests on who holds the private key, not on the servers in between.

## How it works

The key is an **Ed25519** key pair:

- The **private key** exists only on the publisher's Mac, in its login keychain, with an offline backup. It is used for
  one thing: signing.
- The **public key** is compiled into every doz (`Distribution.updatePublicKey`). It is used for one thing: checking.

### Publishing (on the publisher's Mac, by hand)

`make publish-recipes` (`Scripts/publish-recipes.sh`):

1. stages the recipe data with the next **serial** number (unchanged data publishes nothing);
2. writes the manifest — format, product, serial, date, the oldest doz that can use it (`minimum_doz`), the version it
   was made from, and every file's path, sha256 and size — and signs ONE message built from it;
3. checks the signature against the public key doz carries (a key doz would not trust is refused here);
4. has this build's doz load the staged catalogue in a scratch run — it must accept it;
5. only then writes `v1/recipes.json` and `v1/recipes/<serial>/` into the site, commits, and pushes with `PUSH=1`.

### Checking (on every Mac running doz, automatically)

About once an hour the doz host downloads `v1/recipes.json` (the manifest and its signature) and:

1. checks the signature against the public key compiled in;
2. checks that the serial is newer than the catalogue it has, that this doz is at least `minimum_doz`, and that the
   catalogue was not made from an older tree than this doz (`source_version`);
3. downloads each file the manifest names and checks its sha256 and size;
4. checks that the merged recipe set passes every rule the built-in set passes.

If everything passes, the catalogue is used from the host's next start. If anything fails, the **whole** catalogue is
ignored, doz keeps the recipes it already has, and says so once (and always in `doz doctor`'s `recipes` line). A
tampered file is never kept.

So an attacker who controls the servers can **delay** new recipes, but cannot **change** them and cannot **roll
back** to an older catalogue.

## Is the recipe data encrypted?

No. It is **signed, not encrypted** — public and readable by anyone. Signing proves who wrote it and that it was not
changed; encryption would hide it, and nothing in a recipe is secret: the recipes are in this public repository, and
`v1/index.json` beside the catalogue is published plainly for the website and anyone else to read.

- The download itself is over HTTPS, as any website is.
- The request carries only doz's version in its user agent — no account, no API key, nothing about your sandboxes.
- **Your API keys are never in a recipe.** A recipe only names which addresses a key may be sent to; the keys stay in
  your Mac's keychain (or the source you configured) and are added by the host's proxy on the way out.

Encryption would only be needed for something secret, such as a private or paid recipe meant for some people only.
Nothing does that today.

## Why the update key is reused

The same key signs doz's update feed. The two cannot be confused: every signed message starts with a label naming what
it is (`dozable-recipe-catalogue-v1` for a catalogue, the feed's own label for an update), so a signed catalogue can
never verify as an update or the other way round. Tests check this byte for byte, and the signing script refuses to
sign a catalogue message without its label.

A second key would sit in the same keychain on the same Mac, used by the same person — a thief would get both. Neither
key can be changed without a doz release, because its public half is compiled into every installed doz. A separate,
narrower key becomes worth it only if publishing ever moves somewhere else (for example an automated build machine).

## What the key cannot do, and what it can

- It **cannot** change the built-in agents (Claude Code, pi, Codex): their recipes are fixed in each release and a
  catalogue's copy of them is ignored.
- It **cannot** remove a recipe: a catalogue only adds or replaces, so every name a sandbox uses keeps working.
- It **can**, together with control of doz.sh, replace any other recipe and any model provider's entry — including
  which addresses a provider's key is sent to — for sandboxes made after a host restart. That is why the private key
  must never leak.

## Looking after the key

1. **Never lose it.** Without the private key no new catalogue or update could ever be signed for the doz already
   installed. Keep the offline backup.
2. **Never let it leak.** It lives only in the publisher's login keychain and the offline backup; it is never written
   to a file, a log, a repository or a build machine.
3. **Keep doz.sh renewed.** Every doz from this release on asks doz.sh. A lapsed domain cannot push a false catalogue
   into doz, but no one would get new recipes, and a new holder would see each request's address and doz version.

## Community catalogues

A community catalogue uses the same format and checks, signed with **its publisher's own key**, which you confirm by
its fingerprint when you add the source (`doz recipe source add URL --key KEY`). Dozable's key is refused as a
community key. See "Your own recipes and community catalogues" in [`recipes/RECIPE-FORMAT.md`](recipes/RECIPE-FORMAT.md).
