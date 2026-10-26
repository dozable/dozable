# Your own recipes, and community catalogues

Every tool Dozable runs comes from a **recipe**: a YAML file that says how the tool is installed, how it runs, which
key it uses and what it may reach. Dozable ships its own. You can also write **your own**, and add **community
catalogues** — recipes someone else publishes, signed with their key.

A recipe that is not Dozable's is labelled everywhere it is shown: **yours**, or **community · NAME** — in
`doz search`, in `doz try`'s list, in the plan, and on the dashboard's Quick try and New Sandbox. It can never use the
name of one of Dozable's own recipes.

## Your own recipe

```sh
doz recipe new mytool --from opencode     # a copy of one of Dozable's recipes, renamed — a good start
doz recipe new mytool                     # or an empty one to fill in
doz recipe check mytool                   # does it meet the minimum requirements for a community recipe?
doz try mytool                            # use it like any other
```

The file is `~/.config/doz/recipes/mine/mytool.yaml` (your settings folder). Edit it with any editor — the first line
points editors at the format's schema, so they check it as you type. The format is in the repository's
`docs/recipes/RECIPE-FORMAT.md`.

`doz recipe add ./tool.yaml` copies a file in as one of yours, after it passes the check. `doz recipe ls` lists yours
and every catalogue's: where each came from, whether it is in use (or why it was refused), and whether it was checked.

## The minimum requirements for a community recipe

`doz recipe check` goes through them one by one, then gives one verdict. Every recipe that is not Dozable's must meet
them, or it is not used:

- it is a schema 2 recipe, read strictly, and passes every rule Dozable's own recipes pass;
- its name is none of Dozable's, and it is not a built-in agent;
- its maker, its link (https), its licences and a description are filled in;
- its text is plain: no control or direction characters, a short name and description;
- every download is pinned with its checksum — and Dozable installs exactly that release, never a newer one;
- it has a guide and a check turn;
- it names no credential, and holds nothing shaped like a key;
- it hides nothing: no hosts kept out silently, no hidden hosts it may reach — only permissions you see;
- it wears no mark from Dozable's icon registry, and belongs to no family of versions.

**`doz recipe check mytool --full`** also builds and tries it for real, on this Mac, in a scratch folder (minutes the
first time — the image is built there and kept for the next run). It uses fake keys and a stand-in for the model
provider, so no real key is involved: the image is built at its pinned release, its verify commands run, a fresh
sandbox's first screen is read (no setup wizard, sign-in or consent question), its check turn runs and must answer,
its guide's steps run, and Dozable checks that only a placeholder of the key is in the sandbox and that the placeholder
sent anywhere else is refused. It does not check the tool's status reports, its web ports, every model provider it can
use, or a tool that answers only through a tool call.

A pass is recorded with the checksum of the file that passed: `doz recipe ls` says when the file has changed since.

## Community catalogues

```sh
doz recipe source add https://example.com/v1/recipes.json --key BASE64KEY
doz recipe source ls
doz recipe source rm example
```

Adding one shows its publisher's key **fingerprint** (`SHA256:…`) and asks whether it is the one the publisher gave
you — compare it with what they publish. Nothing is downloaded before you confirm. In a script, give the fingerprint
you checked: `--fingerprint SHA256:…`.

A catalogue is used **whole or not at all**: if it is tampered with, signed with another key, or offers a name that is
already taken (by Dozable, by yours, or by a catalogue added earlier), none of it is used, and `doz recipe source ls`
says why. Dozable looks for a newer catalogue hourly while its host runs.

Before a sandbox of a community recipe is made, Dozable says whose recipe it is, what its image build installs and
reaches, and asks once for each version of it. `doz recipe trust NAME` says yes ahead, for scripts. On the dashboard,
Quick try's setup shows the same under **Whose recipe** before Start. Your own recipes are said, never asked.

## When a change applies

When no Dozable host is running, a change to your recipes or catalogues is used at once. While one runs, it applies at
its next start — `doz host restart` — so every command keeps using what the running host uses. A running dashboard
shows it after `doz ui restart`.

## Removing one

`doz recipe rm mytool` and `doz recipe source rm NAME` never break a sandbox made from the recipe: it is kept,
unpublished — it is offered nowhere, and a new sandbox of it is refused, but every sandbox made from it keeps working,
and its name stays theirs. `doz recipe ls --all` lists the kept ones; `doz recipe rm mytool --forget` drops one once no
sandbox uses it.

## Publishing a catalogue

A catalogue is the same format as Dozable's own recipe catalogue, signed with **your** key. From a checkout of the
Dozable repository:

```sh
swift Scripts/update-key.swift community-key ~/keys/my-recipes.key      # once: prints the public key and its fingerprint
make publish-recipes COMMUNITY=1 RECIPES_DIR=~/my-recipes UPDATE_KEY_FILE=~/keys/my-recipes.key UPDATES_DIR=~/my-site
```

It compiles every `*.yaml` in `RECIPES_DIR`, signs the catalogue with your key, checks that Dozable would use it
(`doz recipe source verify`), and writes `v1/recipes.json` and `v1/recipes/<serial>/` into your site's folder — never
pushed unless you add `PUSH=1`. Publish your public key and its fingerprint where people can compare them. Run
`doz recipe check --full` on each recipe before you publish it.

Your recipes never use Dozable's keys or its usage statistics: nothing about a recipe that is not Dozable's is counted.
