# Recipes: agents, key providers, the catalogue

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableKit/RecipeCatalogue.swift`; `Sources/DozableHost/RecipeCatalogueClient.swift`; `Scripts/publish-recipes.sh`, `recipe-catalogue.py`, `test-recipe-catalogue.sh` | 652: the recipe catalogue — the active recipe set (embedded, or a signed catalogue merged over it, chosen once at start), the manifest + its domain-separated message, the merge and checks; the cache in the settings dir, the choice, the host's daily refresh; the publisher and its end-to-end test |
| `Sources/DozableKit/RecipeOrigin.swift`, `CommunityRequirements.swift`, `StandInProvider.swift`; `Sources/DozableHost/RecipeExtras.swift`; `Sources/DozableCLI/RecipeCommands.swift`, `RecipeFullCheck.swift`; `components/source-pill.js`; `Scripts/test-community-recipes.sh` | 653: recipes that are not Dozable's — their origin, the community requirements, the merge (`RecipeCatalogue.adoptExtras`); your own recipes, community sources, the snapshot a host start chooses, kept/checks/trusted; `doz recipe …` and the full check (a Swift stand-in provider); the dashboard's pills; the end-to-end test |

## Agent recipes and key providers

- **Every agent is a recipe** (`Sources/DozableKit/AgentRecipe.swift`; data in `Sources/DozableKit/Recipes/compiled/*.json`,
  `providers.json`, `gateways.json`, `tags.json`, each ONE `.embedInCode` line in Package.swift with a unique basename —
  `AgentRecipeTests` ties the folder to the manifest).
  **A recipe's SOURCE is YAML** (owner: one file per recipe, aligned with Docker Sandbox Kit v3):
  `Recipes/agents/VENDOR/PRODUCT.yaml`, `schema: 2` — the spec is `docs/recipes/RECIPE-FORMAT.md`, the contract
  `schema/dozable-recipe-2.schema.json` (each YAML's first line points editors at it). DozableKit never parses YAML (the
  audit keeps Yams in DozableCLI): `make recipes` compiles each to `Recipes/compiled/PRODUCT.json` (`RecipeSource`,
  YAML 1.2 core schema — `no` is a word — no anchors), committed and embedded; `RecipeSourceTests` fails when one
  drifts. `RecipeDocument` decodes it STRICTLY (unknown key anywhere = error; Kit's DERIVED parts — runtime allow/deny,
  a credential's apiKey — must equal what Dozable derives) and maps it one for one to `AgentRecipe`, which everything
  else uses unchanged. `RecipeSchemaTests`: every recipe valid against the schema, the loader refuses what the schema
  refuses (mutations), the Kit view (`kitDescriptor()`) valid against Kit v3's own schema
  (`Tests/Fixtures/kit-v3/`, vendored at a pinned commit), the mapping lossless. Edit the YAML, run `make recipes`,
  commit both; never edit `compiled/` by hand. Decoded once, validated, unknown keys refused; an invalid
  built-in recipe is a test failure. `AgentKind` is a recipe-backed struct (the same raw strings); `allCases` is the
  four that were the enum, then the recipe agents in file order (then a recipe catalogue's new ones, in path order).
  Besides a signed recipe catalogue chosen at a process's start (below), `AgentRecipes.registerForTests` is the only
  way to add one at run time — no environment variable loads a recipe outside a guarded test run's catalogue seam.
- **Published or not** (629, owner: "withdraw most of the recipes … set to 'unpublished'"): `directory@1` `published: false`
  (gateways.json's too) — `AgentRecipes.published` / `Gateways.published` / `ModelSources.isPublished` feed EVERY list a
  person picks from and the per-recipe work (recipe-check `all`/`--changed`, profiles, agent-currency via
  `Scripts/recipes_published.py`, the hourly look-up); `AgentRef.resolve` (typed input only) and `--gateway` refuse a new
  sandbox of one. The FULL set (`AgentRecipes.all`, `AgentKind.allCases`, `ImageChoice.parse`, `recipe(id)`, `Gateways.all`,
  `ModelSources.ids`, `offeredSources`, the settings schema) stays the validator and the resolver of every STORED name — an
  existing sandbox, image, account and setting keep working. Tests of an unpublished tool's mechanics use
  `AgentRecipes.publishEverythingForTests` (a seam, like `registerForTests`); `UnpublishedRecipesTests` pins the set.
- **The recipe catalogue** (652, owner: "decoupling the known recipes from the cli build"; `Sources/DozableKit/RecipeCatalogue.swift`,
  `Sources/DozableHost/RecipeCatalogueClient.swift`): the recipe data as SIGNED DATA beside the update feed —
  `Distribution.recipeCatalogueURL` (`https://doz.sh/v1/recipes.json` since 670 — Dozable's recipe directory, a GitHub Pages
  site of its own; the host is `RecipeOrigin.directoryHost`, a test ties the two; builds before 0.37.37 asked
  `updates.dozable.com`, where nothing is published and a 404 is "none"; the ONE constant) + the files it
  names under `v1/recipes/<serial>/` (a new serial is a new folder), read from the host the manifest came from. `/v1/` is the format (`format: 1`; a new one is
  `/v2/` beside it); the manifest is decoded strictly (an unknown field = a newer doz). Rules that each matter:
  - **The key**: Dozable's update key (`Distribution.updatePublicKey`) — NO other key; ONE Ed25519 signature over a
    DOMAIN-SEPARATED message (`RecipeCatalogueManifest.message`: `dozable-recipe-catalogue-v1\n` + format, product,
    serial, date, minimum_doz, source_version, base + `file: PATH SHA256 SIZE` per file, sorted). A feed entry's message
    starts `dozer-sandbox update v1\n`, so neither can verify as the other (tests replay both ways);
    `update-key.swift sign-catalogue` signs ONLY a message with the catalogue's prefix.
  - **ONE recipe set per process, chosen at its start, never swapped**: every loader that read `PackageResources.*`
    (`AgentRecipes.compiled`, `KeyProviders.file`, `Gateways.all`, `CapabilityTags.all`, `Categories.file`,
    `KnownThings.all`, `AgentIcons.all`/`files`) reads `RecipeCatalogue.active` — `RecipeSet.embedded` (lazy, part by
    part, today's `fatalError`s) unless `DozableEntry.main`'s FIRST statement (`RecipeCatalogueSelection.chooseAtStart`)
    adopted a catalogue, then `RecipeCatalogue.seal()` (an adopt after it is a precondition failure). DozableKit never
    reads the settings or the network for it — DozableHost decides. Only tests swap (`RecipeCatalogue.resetForTests`).
    678: only the HOST's start adopts at once. Any other process decides WHICH catalogue at its start (manifest,
    signature, the files' sizes and sha256 — a tampered file is still refused there) and leaves the merge and the
    validators — and the extras' adoption — for its first read of a recipe (`adopt(…, deferred: true)`,
    `adoptExtras(…, deferred: true)`, run by `settleDeferred` from `active`/`generation`/`extras`, under a recursive
    lock so another thread's first read waits and the validators' own reads see the candidate). A refusal found then
    leaves the embedded set before the first value is returned, is recorded as a start's refusal is and said once
    (`chooseAtStart`'s `report`). So the set is still decided before anything reads it; most commands (`ls`,
    `sessions`, `exec`, `attach`) never read one — `make test-cli-startup` checks they build no recipe part.
  - **The choice**: a guarded test run only with its seam (`DOZ_TEST_RECIPE_CATALOGUE`), a development build
    (`InstallMethod.development`) only with the seam (a recipe edited in the tree must win), else `<settings dir>/recipes/
    current.json` — and in the HOST's own start (`isHostStart`: `doz host … --foreground`, what the launcher runs) the
    waiting `next.json`, promoted when it passes. So a command always uses what the running host uses; a new catalogue
    applies from the next host start (an idle host with one waiting exits, like a changed program). Used only when: it
    verifies, `minimum_doz` ≤ this doz, `source_version` ≥ this doz (THE floor: never recipes older than the build's
    own), a next's serial above the current's, every file present with its sha256 and size — and the MERGED set passes
    every validator the embedded set passes (`RecipeCatalogue.validateActive`). Any failure: the WHOLE catalogue is
    ignored, recorded in `state.json` (`refused`, `refusedSerials`) and said once (stderr on a terminal, never
    `--json`/`-q`; the host log; `doz doctor`'s `recipes` line always).
  - **The merge**: by id — recipes, providers, keyless sources, gateways, tags, kinds, categories, icon entries; the
    catalogue's entry wins, this build's others STAY (a catalogue never removes: every stored name keeps resolving;
    withdraw with `published: false`); a known entry whose id a recipe now has is dropped. Catalogue files are decoded
    strictly (`RecipeCatalogue.strict`) and their schemas must equal this build's.
  - **The built-in three are NEVER replaced**: a catalogue's copy of claude-code/pi/codex is ignored, a catalogue that
    adds any other `builtin` recipe is refused; the publisher leaves them out. `RecipePinTests` stays the proof.
  - **The refresh** (`RecipeCatalogueRefresh`, the host's loop): at most DAILY (672, owner: "daily (not hourly)" —
    `interval`, kept across host restarts by `state.lastAttempt`; the loop wakes every `tick`, an hour, to see whether a
    look is due; a failure waits the day too),
    conditional GET; 404 = none published (keep, silent — the client must work before the first publish); offline
    silent; a newer one's files fetched one by one, sha256-checked, renamed into `files/<serial>/`, then `next.json`
    atomically; a too-old doz or an older tree's catalogue is skipped silently. Seams: `DOZ_TEST_RECIPE_CATALOGUE` =
    `offline` | an http(s) URL (http only from 127.0.0.1) | an absolute path to a site's recipes.json (used directly,
    no cache); `DOZ_TEST_UPDATE_KEY` is the trusted key for it ONLY in a guarded run.
  - **Statistics**: `UsageSchema.agent(image:)` returns only ids THIS build lists in `UsageSchema.agents` — a
    catalogue-only recipe is counted nowhere until a release lists it (the Worker never sees an id it rejects).
  - **Publishing**: `make publish-recipes [MIN_DOZ=] [DRY_RUN=1] [PUSH=1]` (`Scripts/publish-recipes.sh`,
    `recipe-catalogue.py`): the committed compiled data less the built-in three, the next serial (unchanged data =
    nothing), signed with the keychain key (`UPDATE_KEY_FILE` only with `TEST_PUBLISH=1`, `RECIPES_DIR` likewise),
    checked against the key doz carries, then THIS build's doz must use it (a guarded run, the file seam) — only then
    `DIRECTORY_DIR` (the doz.sh Pages repository's checkout, `Makefile.config`; never the update site: a folder holding
    `v1/feed.json`, the same folder as `UPDATES_DIR`, or a `CNAME` naming another host is refused before anything is
    written) is written — `v1/recipes.json`, `v1/recipes/<serial>/`, `v1/index.json` (`doz search --index` in the guarded
    run: `dozable-directory/v1`, UNSIGNED and beside the manifest because its path set is closed — a new manifest path
    is a `/v2/` matter), `CNAME` (the constant's host), `.nojekyll` — and committed; pushed ONLY with `PUSH=1`, which then
    waits until the live catalogue says the serial. The first live publish waits for the owner.
  - **Tests**: `RecipeCatalogueTests` (format, signature both ways, minimum doz, floor, serial, merge, built-ins,
    refused whole, statistics, the choice, the refresh); `make test-recipe-catalogue` (`Scripts/test-recipe-catalogue.sh`:
    publish an edited tree with a throwaway key → a local server → a real host's refresh, 404 then the catalogue → the
    next host start applies it → new processes use it; a tampered file never used; idempotent; nothing pushed).
- **Recipes that are not Dozable's** (653, owner: "allow the end-user to create their own with the option to verify as
  meeting the minimum requirements for a community recipe"; RECIPE-FORMAT.md "Your own recipes and community catalogues"):
  - **Origins**: `AgentRecipe.origin` (Dozable's, `mine`, `community(NAME)`) is OUTSIDE the coding keys — a recipe's JSON and
    every bake key are unchanged (`RecipePinTests`). Shown everywhere a recipe is ("yours", "community · NAME"): `doz search`,
    `doz try`'s list, the plan (`CreatePlan.recipe`, `PlanRecipe`), the dashboard's Quick try cards/details/setup and New
    Sandbox's chips (`components/source-pill.js`). `doz search --index` writes Dozable's only.
  - **The merge**: `RecipeCatalogue.adoptExtras` runs after 652's choice and before `seal()` (`DozableEntry` →
    `RecipeExtras.chooseAtStart`), source by source, WHOLE or not at all: every recipe meets `CommunityRequirements` (a closed
    list — `doz recipe check` prints it), no id/alias of Dozable's set or an earlier source's, every validator passes.
    Order: yours → kept (removed, unpublished) → community sources in the order added; a kept id stays its sandboxes' (another
    source offering it is refused — never put under an existing sandbox). Only recipes are added. A non-Dozable recipe is
    `isPinnedOnly` (its pin, never a looked-up latest — every former `pinnedOnlyKinds.contains` site uses it), drawn with a
    lettermark, never counted (`UsageSchema.agent(image:)`).
  - **One snapshot per host start** (`<settings>/recipes/in-use/`): a host's start (and a `doz recipe` command when no host
    runs for its store) rebuilds it — your YAML compiled (the CLI hands in `RecipeSource.compile`; Yams stays in the CLI), the
    confirmed community caches promoted (652's cache layout per source, `community/<name>/`), the kept ones — and every process
    adopts it. So a command uses what the running host uses; a change applies from the next host start.
  - **Community sources**: `sources.json` (URL, Ed25519 key, `SHA256:` fingerprint, when confirmed). Nothing is fetched before
    the fingerprint is confirmed (a terminal question, or `--fingerprint`); Dozable's own key is refused as a source key; https
    only (http from 127.0.0.1 in a guarded run). A community catalogue is 652's format with `product: doz-community-recipes`
    and `agents/` only, signed with its publisher's key; the host refreshes each daily beside Dozable's (`CommunityRefresh.interval` = Dozable's).
  - **Trust**: the CLI asks once per recipe version (`trusted.json`, by id + sha256) before a COMMUNITY recipe's sandbox is made
    (`confirmRecipeTrust`: QuickMake before its image is prepared, `preflightAgentAccount`); no terminal → exit 5 naming
    `doz recipe trust ID`. Your own are said, never asked. The dashboard shows "Whose recipe" first in the try setup.
  - **The full check** (`doz recipe check --full`, `RecipeFullCheck`): this executable as child processes in a scratch store
    under the guarded test environment, fake keys, `StandInProvider` (a Swift TLS stand-in, SandboxCA's multi-host leaf) behind
    the provider/OpenAI seams; build at the pin, a fresh Locked isolated try, the first screen (openpty), verify, the check
    turn (the fake key seen), the guide's steps, keys + the leak guard. NOT OSC 7501, web ports, other model sources, tool-call
    answers. Passes recorded by sha256 in `checks.json`.
  - **Publishing**: `make publish-recipes COMMUNITY=1 RECIPES_DIR= UPDATE_KEY_FILE= UPDATES_DIR=` (`update-key.swift
    community-key` makes a key); `doz recipe source verify` must accept it first; never pushed without `PUSH=1`.
  - **Tests**: `CommunityRecipesTests`; `make test-community-recipes`; the workspace probes `probes/653-*/` (`full-check.sh`,
    `browser-community-labels.mjs`).
- **The built-in three (Claude Code, pi, Codex) keep every byte**: their recipes are `builtin` and only DESCRIBE them
  (credentials, sessions, resume, settings keys, prompt); their install steps and launchers stay `AgentImages`' Swift.
  `RecipePinTests` (Codex included) must stay green; `RecipeAgentsTests.test_builtinRecipesDescribeTheirImages` proves
  each recipe matches its image. `AgentPackage.integrity` is nil for them (absent from the canonical JSON).
- **A recipe agent** (Gemini CLI, Grok Build) is composed from its recipe alone: its install (npm with Node on a base
  without it; an npm platform package at the main package's version, sha512-checked, brotli payload decompressed in
  the bake), the generic launcher (`AgentImages.recipeLauncherScript`: approval prompts off unless
  `DOZ_<SHORT>_PERMISSIONS=ask` or root, passthrough arguments run as they are, first-run settings written ONLY when
  absent), its persist dirs and session environment. A recipe names no credential (validated). Its version resolves
  from the MAIN npm package (Grok's platform package's own `latest` tag is stale).
- **Conversation history** (674; `launch@1 history`, `Sources/DozableHost/AgentHistory.swift`, `AgentHistoryTests`): an agent
  that deletes its own conversations after a while (Claude Code: `cleanupPeriodDays`, 30 days) gets the vendor's own keys
  that mean "keep" — `history.keep: [{file, set}]` (1–4 entries, `~/….json` or `~/….toml`, dotted keys, scalar values, never a credential's
  name, validated like `first_run`), with `agent_default` (what the agent does by itself), `source` and `checked`.
  **Never baked**: no `ImageSpec`/`recipeLauncherScript` reads it, so no bake key moves and no image is "older recipe"
  (`RecipePinTests`, `test_nodeImagesAreByteIdentical`, `test_builtinRecipesDescribeTheirImages` are the proof — keep them
  unchanged). Set ONCE per sandbox, in the guest set-up, exactly like the dotfiles (never at a session open — that raced an
  agent rewriting its own file and re-added a key the person had deleted): the host hands the `Sandbox` an
  `AgentSettingsInputs` (`AgentHistory.inputs(for:)` — the python3 script + a sha256 fingerprint of the mapping and the value;
  `HostCore.applyAgentSettingsInput`, beside `applyDotfilesInput`), and `Sandbox.applyAgentSettings` runs after the dotfiles in
  `start()` and in `LifecycleStep.applyGuestFixes`. One cheap check exec as the image's user reads the marker
  `~/.local/share/doz/history.applied`; only when it differs from the fingerprint is the script run, and the marker is written
  afterwards either way (a failing run is not retried at every wake). A key the person deletes afterwards stays deleted; a
  changed mapping or value applies once more. The result is `<sandbox>/agent-history-run.json` (`AgentSettingsRun`: when,
  fingerprint, applied | failed, notes); notes also go to the boot log, never fatal. A preparation VM, a bake or a helper is
  handed nothing and never runs it (`AgentSettingsLayer`, `AgentHistoryTests`). `keep`: a key is set only when absent
  (parents made), a present value is the person's and left alone. `agent-default`: a key is removed only when present AND
  equal to the recipe's value, type included (and a parent object / TOML table it leaves empty — a TOML header goes only
  when nothing but blank lines is left under it); a missing file is not made. Either way: a file that does not parse is
  never written (unlike the launcher's setup, which replaces one — that one is baked and waits for a launcher change), a
  missing file is made 0600 with its folders, atomic temp + rename, no rewrite when nothing changes. **TOML** (Codex's
  `~/.codex/config.toml`): no base can be assumed to have a TOML writer (or `tomllib`, read-only and 3.11+), so the script
  edits LINES and only files it fully reads — blanks, comments, `[table]` / `[[array]]` headers (bare or quoted key parts),
  `key = value` (multi-line strings and arrays followed to their end); anything else is "does not parse". `keep` inserts
  `key = value` under an existing `[table]`, or appends a new `[table]` when nothing defines it; a table made by dotted
  keys, a sub-table header, an array of tables or a value in the way is left alone with a note (never a second
  definition). Every published coding agent has a mapping (owner, 2026-11-04): Claude Code and Codex write; pi, OpenCode
  and OpenCode 2 are `native: keeps` + `note` (nothing written, `inputs(for:)` is nil); another recipe has none — "not
  known", and no setting. A catalogue recipe that uses `history` needs `minimum_doz` raised, as `sign_in` does.
- **The history setting** (674 Step 2; `Settings.swift`, `AgentHistory.swift`, `SettingsTests`, `SettingLayersTests`):
  `agent.history` (`keep` | `agent-default`, default keep, class S) and, ONLY for a recipe with `launch.history`,
  `recipes.V.P.history` (`follow` | `keep` | `agent-default`, default follow — `recipeSchema`, like `approvals` for an agent
  with prompts). A project's / sandbox's own is the recipe word `history` (`DozableSettings.recipeWords`, beside
  `approvals`: `history:` in doz_project.yaml, `doz config set --sandbox NAME history …`, also taken by the recipe's full key
  or `agent.history`). Effective value: `DozableSettings.history(agent:own:from:)` — the most specific value that is not
  `follow`: sandbox/project, the recipe's on this Mac, `agent.history`, with the source and the key that decided it.
  `applies: next-start-or-wake` (the guest set-up), never next-session. The host resolves it per sandbox in
  `applyAgentSettingsInput` — at load, before every request about the sandbox (`perform`), in `ensureRunning` (a wake by
  use) and after a `sandbox-settings` change — and the value is in the fingerprint, so a changed setting applies once.
  `SettingRow.history` (`[HistoryMapping]`) carries what each value does in each agent: `agent.history`'s row every
  published coding agent's (and any mapped one), a recipe's row its own; the Settings page and the recipe page draw it with
  `settingMatrix` (rows = agents, columns = keep · agent-default, the value it gets marked — no new control),
  `doz config show --agent ID` prints it (`ConfigShow.historyLines`). `history` is a common option name (`settings@1` may
  not declare it).
- **The agent's config folder on this Mac** (683; `launch@1 mac_config`, `AgentRecipe.Launch.MacConfig`,
  `AgentRecipe.validateMacConfig`, `Sources/DozableHost/MacAgentConfig.swift`, `MacAgentConfigTests`): what a FENCED `@mac`
  session of the agent gets for its own settings folder — `home_env` (`CLAUDE_CONFIG_DIR`), `home` (`~/.claude`), `beside`
  (`~/.claude.json`), `link_read_only` (instructions, skills, agents, commands, output styles), `clean_copy` (settings
  keys copied from the person's), `first_run` (onboarding, the workdir trusted), `transcripts`
  (`projects/{workdir}`, `*.jsonl`, the `claude` encoding) and `default` (`private`). **Untrusted input, a fixed shape**:
  honoured ONLY from a recipe embedded in this build — `RecipeCatalogue.merged` refuses a catalogue recipe carrying it,
  `CommunityRequirements` (`no-mac-config`) a community or personal one, and `AgentRecipes.macAgent(program:)` (the
  `argv[0]` → recipe match for `@mac`) looks at `RecipeSet.embedded` only — so no other recipe can claim `claude`. The
  validator: `home` a single dot-folder in `~`, never a closed one (`macConfigClosedHomes`: `.ssh`, `.config`, `.aws`, …);
  `beside` exactly `home.json`; `home_env` `^[A-Z_]+_(HOME|CONFIG_DIR)$`; names one level deep, no `..`; settings keys
  dotted names, never `env`, `apiKeyHelper`, `hooks`, `statusLine`, `enabledPlugins`, `mcpServers` or a credential's name;
  `transcripts` fixed. **Never baked** (no bake key, image or launcher reads it). The setting `recipes.V.P.mac_config`
  (`follow` | `private` | `shared`) exists only for a recipe that declares one; `mac_config` is a common option name.
- **Keys** (`KeyProviders`): a `key` account carries its provider (`doz account add NAME --provider xai|google|opencode|…`,
  `doz-<provider>:NAME`, per-provider defaults in `AccountsFile.providerDefaults`); the binding is the provider's
  (xAI: Bearer on api.x.ai; Google: `x-goog-api-key` on generativelanguage.googleapis.com — never
  `GEMINI_API_KEY_AUTH_MECHANISM`). A key agent's sandbox NEVER gets an Anthropic binding (`applyKeyAccount`). The key
  check is the provider's (`KeyProvider.check`; xAI and Google answer a bad key with 400). The proxy refuses in each
  provider's error shape. Test seam: `DOZ_TEST_PROVIDER_UPSTREAM` + `DOZ_TEST_PROVIDER_CA` (the proxy's leg and the
  key check go to a fake, trusting only its CA; `probes/617-*/stageA/` is the VM proof).
- **Model sources** (`ModelSources.swift`; RECIPE-FORMAT.md "Model sources"; owner: "add OpenAI and Anthropic AND gateway
  support"): providers.json lists each provider's endpoints by API shape (openai-chat, openai-responses,
  anthropic-messages, gemini) with a default model; OpenRouter and Vercel AI Gateway are key providers (`gateway: true`,
  endpoints from gateways.json). A recipe may declare `models@1` (the shapes it speaks with `${{ dozable.base_url }}` /
  `${{ dozable.model }}` env and `key_env`, native sources, except, per-source models); it is then offered every source
  serving one (`AgentRecipe.offeredSources`). The sandbox's ACCOUNT decides the source (`AgentCredentials.source(of:)`:
  `api-key` = Anthropic, `openai-key` = OpenAI, `key` = its provider — never a subscription); `applyMainAccount` binds
  that source's key (its hosts only), `HostCore.recipeEnvironment` sets the selection's env at every session open and
  exec (never over the caller's; nothing baked), `SandboxConfig.models` keeps a chosen model per source. `--provider` /
  `--gateway` / `--model` (ChoiceOptions → `CreateOptions.modelSource/model`; `AgentCredentials.account(forSource:)` picks
  that source's key), the plan's `model` (+ every offered source), the Quick try setup's Model section, New Sandbox's
  chooser (`WebAccounts.sources`). **A recipe agent's sandbox decrypts every model source's hosts**
  (`EgressProxy.leakGuardHosts`) so a placeholder sent to another source is refused, never tunnelled unseen. Codex keeps
  its own flow (`AgentCredentials.codexFlow` — never "provider == openai"). 618 (owner: "openrouter can behave as an openai compatible model API"): a gateway models@1
  offers needs no gateways@1 entry — `AgentRecipe.gatewaySupport` derives it (`documented`, citing the shape's `source` /
  the native entry's `docs`); an entry only overrides (`verified` + evidence once recipe-check ran it, no `how` needed),
  and a models@1 recipe's entries may never contradict what a try can do (`offersGateway`). The Quick try's "Through a
  gateway" is `throughGateway`; `doz search` marks the offered ones; the tags read `gatewaySupport`. A tool that takes its model
  only on its command line declares `launch.model_args` (`[-m, $DOZ_MODEL]`; the launcher puts them first when
  `DOZ_MODEL` is set, never over the run's own flag or for a passthrough subcommand — `RecipeModelArgsTests`); one that
  takes it only from its settings file, a `first_run` entry with `each_run` (written at every run, `$DOZ_…` filled in,
  never a key — `RecipeEachRunTests`; the helper then runs before the passthrough). Both only in such a recipe's launcher. pi (built-in) declares
  models@1 too — native only, at session time: `AgentCredentials.sources` includes it, a non-Anthropic key goes the
  recipe agents' way in `applyMainAccount` (an Anthropic one keeps pi's own path, `doz key set` included), its other
  sources' hosts are the hidden `sources:pi` permission (added at create, like Codex's `model:openai`), and the host puts
  its `--model` on the default session (`builtinModelArguments`: off Anthropic, or a model chosen there). Its image and
  launcher are unchanged (`RecipePinTests`). Codex records why a gateway is not offered (its gateways entries'
  `limits`). 660 (618.B4): Claude Code declares models@1 — `anthropic` native (its own three accounts, its own model unless
  one is chosen: `launch.model_args` on the default session only then, `PlanModel.own`), the `anthropic-messages` shape
  (OpenRouter / Vercel's Anthropic endpoint: `ANTHROPIC_BASE_URL`, the key's placeholder in `ANTHROPIC_AUTH_TOKEN`, the model
  in `ANTHROPIC_MODEL` + every `ANTHROPIC_DEFAULT_*_MODEL` + `CLAUDE_CODE_SUBAGENT_MODEL`,
  `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1`) and `local` — a model server on this Mac (`MacModelServer`: id `local`,
  key-less, offered by a native entry only, `{base_url}` = `http://mac.dozable.internal:PORT`, a model required, its
  `key_env` given `dozable-no-key`). Claude Code's default account stays the Anthropic default (`AgentCredentials.defaultAccount`
  never falls into a gateway); the try setup and New Sandbox keep its account chooser on the Anthropic row. The image and
  launcher are unchanged (`RecipePinTests`). Manual 32. A source that takes NO key (providers.json `keyless`: `opencode-zen`, OpenCode Zen's free
  models — OpenCode 2 sends its own "Bearer public") is never a key provider: no binding, no placeholder, no account
  (`AgentCredentials.account(forSource:)` answers `none`; `--account` refused; `doz account add` refuses it), offered
  only by a `native` entry, its host in the recipe's model permission path by path (`/zen/v1/chat/completions`,
  `/zen/v1/responses`), still watched by the leak guard. A try records it as `SandboxConfig.modelSource` and uses it
  while it has no account (`HostCore.keylessSource`; an account added later wins); its vault holds no key at all. Its
  model list is curated — the free models the docs list AND the pinned release enables without a key — each with its
  data terms (`ModelInfo.note`, `ModelList.kind` `listed`). recipe-check runs it with no account and fails on any
  credential at its host or any refusal in the Locked try. `make recipe-check` runs a models@1 recipe
  once per offered source (`RECIPE_SELECTIONS`), `ModelSourcesTests`, `probes/617-*/recipes/models/browser-try-models.mjs`.
- **Model lists** (618, owner: "… its also missing the step to choose a model"; `ModelLists.swift`, `HostCore+Models.swift`):
  a gateway's PUBLIC list (OpenRouter `/api/v1/models`, Vercel AI Gateway `/v1/models` — no key) is read by the HOST on
  the Mac, never a sandbox — the read-only op `models` (`modelsSource`, `modelsRefresh`) reads it when a day old (not
  within 10 min of a failure; one read per gateway at a time; offline silent, the last list kept) into
  `<store>/model-lists.json` (Resources: Dozable's own records). Strictly decoded (`ModelLists.parse`: text models only, a
  bad entry dropped, ids `isModelID`, text inert and capped, prices per million tokens), ≤ 3000 entries. A provider
  (Anthropic, OpenAI, xAI, Google) lists only with a key, so its list is the checked default (`kind: default`) — any id
  may be typed. In-process (no host) answers the cache only; the real host's fetcher is `ModelListFetcher.fromEnvironment`
  (`DOZ_TEST_MODEL_LIST=offline|FILE|DIR`; a guarded run without it reads nothing). `doz models [--gateway|--provider]
  [SEARCH] [--refresh]`; `--model` with a gateway gets a did-you-mean NOTE (`ModelNote`, never a refusal — lists go
  stale) in `requestPlan`, `create` and `up`. The web route `GET /api/v1/models/{source}` → `WebModelList` (the default
  first). `ModelListTests`; fixtures `Tests/Fixtures/models/` (trimmed real lists + crafted edge cases).
  **The choice in the dashboard** (owner: "open router should be part of the key choices; needs rethink"; workspace mockup
  `changes/618-*/try-model-source.html`): ONE section, "Where TOOL gets its model" (`components/model-source.js`:
  `sourceList` — providers then gateways as equal rows, each with its key status, the chosen row's key / choice of keys /
  paste under it — and `modelPicker`, fed by `GET models/SOURCE`, searchable, a typed id allowed). The Try setup
  (`sourceSections` in `views/try.js`: a choice re-plans with that source's default key; the plan's "Same in Terminal")
  and New Sandbox's Account step (`nwModelSource`) both draw it; `WebAccounts.sources` includes a built-in agent that
  declares models@1 (pi), plus `gatewaySources` / `sourceModels`; `WebPlan.Model.Source.keysPage`. A tool with no choice
  (Claude Code, Codex) keeps its Key section. **`doz_project.yaml` `model_source:` / `model:`** (owner: yes):
  `DozableProject.modelSource/model`, checked by `modelProblem()` (an id `isModelID`; the source one the agent is offered,
  else the fix names them), into `createOptions`; `doz init --provider/--gateway/--model` write them, `doz up`'s flags win
  over them, the plan's yaml echoes them (the "not project keys" note is gone), New Sandbox writes them
  (`WebProjectForm.modelSource/model`, explicit keys `model_source`/`model`). Workspace probe
  `probes/618-*/models/browser-model-source.mjs` (1440/390, light/dark, overflow).
- **The guide** (617.11, owner: "i tried fabric and it just gave me a terminal … our companion guide"; `RecipeGuide.swift`,
  `SandboxGuide.swift`, `components/try-guide.js`, RECIPE-FORMAT.md "The guide"): `guide@1` = intro, ≤ 8 steps
  `{text, command?, edit?}`, ≤ 6 tips, docs, a `notice` (`doz try` says it first). The first step WITH a command is the check turn as a person types it
  (a step without one may come before it — Antigravity CLI's terms, the person's to accept; owner 2026-10-15)
  (`guideMatchesCheck`: `sh -c X` = X, a `${{ dozable.* }}` = the models@1 variable set to it); every command starts with
  the tool's program/command/short name or a plain shell builtin (validated). Every recipe has one (`GuideTests`);
  `make recipe-check` runs every later non-edit step (exit 0). Dozable writes the preamble and facts (`SandboxGuide.make`:
  version, source · model · the account's NAME, network, folder, persist dirs) — `SandboxDetail.guide` → `WebGuide` →
  the inspector's Guide tab (the last tab, on every sandbox — 634: never chosen by itself; Run = `sendInput` +
  Enter into a live pane — the tool's own session for `launch.session: shell`, a shell beside an agent's screen; Type
  without Enter); `doz guide NAME`; `doz try` prints "Start here" for a shell tool; `deliverGuideNote` writes
  `/etc/profile.d/doz-guide.sh` (a shell tool's default session only) — the steps once per user (a stamp in
  `~/.local/state/doz`). `install.extras` bakes pinned file sets (Fabric's patterns at `/opt/fabric/patterns`,
  sha256-checked; `CUSTOM_PATTERNS_DIRECTORY`). `probes/617-*/stageE/browser-try-guide.mjs`.
- **Permissions**: a recipe agent's own `model:<provider>` (Grok's path-conditioned to the API paths it uses — the VM
  proof found `/v1/responses` against the real base) and a hidden `update:<id>` (only beside "Update itself"). D5: a
  sandbox with a recipe agent's own model has NO Anthropic `model` (`normalized` drops it; its Locked is its own model
  only); the built-in three's presets are unchanged. A fresh try shows NO refusal (owner): what an agent calls on its
  own vendor's sites at a normal first run is allowed, each host with its `reason` (the plan's reach lists them) — a
  recipe agent's in its model permission, every agent's (the built-in three's too) in recipe `network.vendor` → the
  hidden `vendor:<id>` added at create like Codex's `model:openai` (new sandboxes only; never in a preset, the
  checklist, the facts' list or a suggestion; permissions are not bake inputs — `RecipePinTests` unchanged). GitHub-
  hosted vendor content only by path (validated; Codex's plugins clone by exact info/refs + git-upload-pack, so never a
  push). `exact_paths` allow one path exactly (`$` in `EgressRule`'s conditions — Grok's key-less `GET /`), and a
  provider's `swap_only` keeps such a call key-less. Self-update is off by the agent's own switch (`launch.session_env`,
  set by the host at session open — pi's `PI_SKIP_VERSION_CHECK`), and `network.off_without` turns off what a permission
  that is off would refuse (Claude Code's `DISABLE_ERROR_REPORTING`/`DISABLE_TELEMETRY` without "Send error reports"),
  said in the plan and the facts (`HostCore.withRecipeEnvironment`). `FirstRunTests`; the VM proof is
  `probes/617-*/stageD/firstrun-netlog.sh` (0 refusals for all five, and example.com from the guest still counted).
  What an agent calls that no setting of its own turns off, when it is to be kept out, is
  `network.quiet` (no recipe uses it now: Antigravity CLI's usage log to play.googleapis.com is `vendor`, owner: do not
  block it), each with its reason: denied first like `excluded`, logged, NEVER counted (`ConnectionLog.quietHosts`,
  set from the policy by `EgressProxy.policy`; `PermissionReport` skips it). `localhost` (RFC 6761) is answered by the
  proxy's DNS as the loopback, never judged or logged.
- **The icon registry** (`Recipes/icons/`: `icons.json` + one mono SVG per entry, `AgentIcons.swift`; docs/DOZABLEKIT.md
  says how to add one): vendor and product marks, a recipe's `icon` names its product; resolution product → vendor →
  a generated lettermark (never blank). A mono file is ONE currentColor path (`MonoSVG.check`, byte-exact); `allowed`
  official | lettermark, with the source, the brand terms checked and the date. Every mark is a Dozable lettermark today
  (`Lettermark`, stroke letters — the file must be exactly what it draws: `AgentIconsTests` draws an empty one). Colour:
  `variants.color`/`color-dark` accepted, never drawn yet. The directory index carries each entry's `icon`.
- **Gemini CLI's `SANDBOX` is NOT set** (checked against 0.63.0's bundle, `probes/617-*/stageE/gemini-sandbox-env.py`).
  It is more than a label. Any value:
  - skips the relaunch that raises Node's heap to half the VM's memory (512 MiB instead of 1 GiB on 2 GiB);
  - removes the supervisor, so an in-app restart (trust change, Google sign-in, admin settings) exits instead;
  - turns off its exit when the terminal goes away;
  - turns off its own docker sandbox;
  - makes /docs and /extensions print their URL instead of opening a browser;
  - turns off its browser agent;
  - changes the system prompt from "outside of sandbox" to "running in a sandbox container".

  The footer would then read "current process", not the value; only /about and /bug show the value. Hiding the red
  "no sandbox" without those side effects is `ui.footer.hideSandboxStatus: true`, which is not set either: that is the
  owner's call. Antigravity CLI reads no such variable: its "sandbox" is its own command sandbox (`--sandbox`,
  `enableSandbox`).
- **Network profiles** (`make profile-agents [AGENTS=…] [DIFF=1]`, `Scripts/profile-agents.sh` + `Scripts/agent-profile.py`
  + `Scripts/fake-provider.py`): a fresh try per agent with the Open network in a scratch store (`/tmp/doz-profile`),
  every HTTPS request decrypted and logged by the PROFILING seam `DOZ_TEST_PROFILE_NETWORK=1`
  (`EgressProxy.inspectEverythingForProfiling`), its first start + a scripted task (`-p`/`exec`, FAKE keys) →
  `profiles/AGENT.json` (version, date, how, each endpoint with credential and a determination: allow / allow-path /
  off-by-setting / refuse + reason). New endpoints come in with `null` — `AgentProfileTests` fails until a person
  decides them, and checks every determination against the recipe under a fresh try's policy (refuse ⇒ quiet;
  off-by-setting ⇒ a setting the recipe sets). `DIFF=1` reports new/missing endpoints and writes nothing; nothing is
  ever allowed by the profiler. Re-profile when an agent's version moves. A profile is of the release Dozable installs:
  `profile-agents.sh` sets each recipe agent's version setting to its PIN (the built-in three: `latest`) before the
  try, and fails when the sandbox reports another version (an updater that ran, or a wrong install — the profile of
  Antigravity 1.3.4 against a 1.3.3 pin was this); `recipe-check` checks the image holds the pin and runs `verify`
  again AFTER the smoke turn; `agent-currency`'s TODOs compare the latest with the recipe's pin (built-ins: with the
  profile), never with the last report.
- **Every recipe is checked for real** (`make recipe-check RECIPES="grok gemini"|all`, `Scripts/recipe-check.py`, driven by
  the recipe's own data — nothing per agent): in a scratch store (`RECIPE_STORE`, default `/tmp/doz-recipe-check`; images
  kept, sandboxes never; it runs a COPY of the build) — build at the pin (the built-in three at `latest`: their pins are
  RecipePinTests' frozen fallbacks), verify again in a fresh try, the recipe's **`launch@1.check`** turn (REQUIRED in every
  recipe: `{argv, expect, exit?, timeout?}`; the stand-in `Scripts/fake-provider.py` — xAI, Google, Anthropic Messages,
  OpenAI Responses, started by `fake-provider-up.sh` — answers `DOZ_FAKE_OK`), the fake key seen by the stand-in and only a
  placeholder in the guest, no key anywhere in it, the leak guard, and for `status: osc7501` idle/working/done held by
  deckhold in an interactive turn (a pty attach typing `say ok DOZ_SLOW`); and FIRST, for every recipe whose default
  session is the agent, its **first screen** (attached on a pty, nothing typed, ~15 s, read back with `deckhold dump`):
  no setup wizard, sign-in, consent, trust or theme question (`SETUP_SCREEN`, less `check.screen.allow`; plus the
  recipe's `check.screen.expect/refuse`) — the owner's first `doz try goose` opened Goose's own wizard, which the
  headless check never sees; `RECIPE_ONLY=screen` runs it alone. A first-run file may be YAML (top-level keys, Goose's
  `config.yaml`; `merge_yaml` is emitted only into such a recipe's helper). A JSON report; `--changed BASE` and
  `--prune-days N` serve the **Recipes** workflow (`.github/workflows/recipes.yml`: m1max2, label `doz-ci` — the CI Mac kept for Dozable alone, changed
  recipes per PR/push, all nightly + `agent-currency` + `profile-agents DIFF=1`, a persistent store in
  `~/Library/Caches/DozableKit-ci/recipes-store`). A new recipe passes it before it ships.
- **OpenCode** (`opencode`, npm `opencode-ai` + the platform package `opencode-linux-arm64`, glibc only; an xAI key, model
  `xai/grok-build-0.1`): it installs `@opencode-ai/plugin` into each config dir in the background (`Npm.install`: skipped
  when `node_modules` exists and `package-lock.json`'s root lists the package) — 28 npm requests at a try's first start,
  refusals under Locked. Its first-run files seed exactly that (an empty `node_modules/.package-lock.json`, the lock's
  root dependency), so it calls nothing but its model; `OPENCODE_DISABLE_MODELS_FETCH` keeps models.dev out (the model
  must then be in its bundled list — `opencode models xai`). No OSC 7501 (recipe-check's status probe saw nothing).
- **A tool's majors** (618, owner: "go with B and one card … make sure there is a way the user can chose an earlier
  major version"; 617.B5's first qualified name): each major is a recipe; `com.dozable/family@1` {family, major,
  title, recommended} ties them (`AgentRecipes.validateFamilies`: one recommended, majors once, the family's name the id
  of the member that predates it — its sandboxes/image/settings/statistics keep it — no other recipe answers to it, each
  pin of its own major). **What a person TYPES goes through `AgentRef`** (DozableKit): `NAME` (a family's recommended
  major), `NAME@MAJOR`, `NAME@VERSION` — `--agent`/`--image`, `doz try`, `doz_project.yaml agent:`, the web plan query,
  `doz search`; a STORED name never does (an existing sandbox never changes major). Turning a recipe back into a typed
  name is `AgentRef.typed` (the family's name only for the recommended major — never a member's id alone: it would mean
  the recommended one). An exact release (`CreateOptions.agentVersion`) is checked like a pin before anything is made
  (`HostCore.exactVersionProblem`: known, or the registry confirms it with its integrity) — a plan problem `version`,
  a create refused; its sandbox's boot bakes its own spec (`imageToPrepare` never prepares another release for it).
  `latest` stays within a member's major (`NpmRegistry.versions`, `newest(in:major:)`). A sandbox records
  `SandboxConfig.agentRef` (`opencode@2.0.29`, display only); the plan's `version` (`PlanVersion`: release, ref, majors,
  `familyLine` — "recommended", never "latest") is the try's first line, `--dry-run` and (with the Guide's version fact)
  how to get the other. Quick try: ONE card per family, a Version choice in its setup that RE-PLANS only (the catalog's
  `family` + `ref`); New Sandbox: one chip, its majors under it. `AgentRefTests`, `FamilyVersionsTests`,
  `MajorChoiceTests`, `WebTryTests`; workspace `probes/618-*/browser-try-version.mjs`.
- **Qualified names** (654, 617.B5, owner: "like a Docker image reference"): `AgentRef` also takes
  `[SOURCE/]VENDOR/PRODUCT[@MAJOR|@VERSION]` — VENDOR is the recipe file's (`AgentRecipe.vendor`, set from the document's
  `VENDOR/PRODUCT` id, OUTSIDE the coding keys like `origin`: no JSON or bake key moves, `RecipePinTests`); PRODUCT the
  recipe's id or its family's name (never an alias); SOURCE `dozable` (implied when absent — `VENDOR/PRODUCT` alone
  NEVER means yours or a community's, so a community recipe cannot pose as `anthropic/…`), `mine`, or a community
  source's name (`RecipeOrigin.reservedSourceNames`: no source may be called `dozable`/`mine`). It resolves through
  618's code; the qualification only CONFIRMS (ids are unique) and a wrong vendor/source is refused with the name that
  is right. 670: `doz.sh/VENDOR/PRODUCT[@…]` (`RecipeOrigin.directoryHost`) is Dozable's own directory = `dozable/VENDOR/PRODUCT` =
  `VENDOR/PRODUCT` (`Qualified.host`, `source` = `dozable`; `prefix` keeps what was typed); it fetches nothing — a lookup in
  the active set. Any other dotted first part, `doz.sh/PRODUCT` and four parts, digests and `:` are each refused in their own words.
  `AgentRef.prefix` keeps the qualification in `text`/`pinned` (a project file written from one keeps it).
  Shown: `AgentRef.qualifiedName` (= vendor + `typed(r)`) in `doz search` (+ `DirectoryIndex.Entry.qualified`), `doz try`'s
  list, `doz recipe show`, Quick try's details ("Full name", `WebTryCatalog.Agent.qualified`); `AgentRef.fullyQualified`
  in the plan (`PlanVersion.recipe`, `--dry-run`'s `recipe:` line), the Guide's `recipe` fact, and
  `SandboxConfig.recipeRef`/`SandboxInfo.recipeRef` (display only, every recipe agent's sandbox from 654).
  `QualifiedNameTests` (the grammar, doz.sh included), `QualifiedChoiceTests`; workspace `probes/654-*/`.
- **OpenCode 2** (`opencode2`, npm `@opencode/cli` + `@opencode/cli-linux-arm64`, glibc; models@1 native: xAI, OpenAI,
  Anthropic, OpenRouter, Vercel — the model through `{env:DOZ_MODEL}` in its opencode.json): its first command starts a
  **background server** (`opencode serve --service`, re-parented to PID 1, 127.0.0.1:49374) that keeps the environment
  of the run that started it — so `launch.service` (generic, any recipe) makes the launcher restart it when it runs with
  another `DOZ_MODEL` (never a key's variable: placeholders differ per run), `start` as the fallback (its restart waits
  for the old server, a zombie the VM's init never reaps). ports@1 49374 "OpenCode web" (auth token: `opencode pair`
  prints a one-use link; change 49374 in it when this Mac's port moved). Proved: only its model is called (Open, every
  request decrypted, its own update/models checks on), no plugin or Code Mode download, its first screen is a session.
  `RecipeServiceTests`; workspace `probes/618-*/` (service-restart.sh, verify-*.sh).
  **Its OpenCode key** (656, owner: "yes" to OpenCode Console and OpenCode Go keys): ONE provider `opencode` — 2.0.29's
  bundle reads `OPENCODE_API_KEY` for both Zen (`opencode/…`, pay as you go) and Go (`opencode-go/…`, the subscription)
  (workspace `probes/656-*/read-bundle.py`, facts-2.0.29.json). The key is CONFINED: `swap_only` + providers.json
  `paths` (its model paths under `/zen/v1/`, `/zen/go/v1/`, `/inference/…`, per shape, and EXACTLY
  `GET /console/api/v2/config` — the Console settings read OpenCode makes at start with an env key; refused, every start
  showed a refusal) → `CredentialBinding.paths`: the vault rejects its placeholder on any other path or an unclean one
  (`isCleanPath`), whatever the network allows. `also_headers` (x-api-key, x-goog-api-key) swaps the placeholder IN
  PLACE for the Anthropic/Google-shaped models (otherwise it would be moved into Authorization). No endpoints (offered
  by the native entry only); `models` listed in providers.json (the pin's catalogue, Go first = the default
  `opencode-go/kimi-k2.7-code`; `ModelSources.defaultModel`); no key check (none exists that costs nothing and is
  verified); a recipe offered it must name every path in its model permission (`validateModels`). The key-less
  `opencode-zen` shares opencode.ai (allowed only beside a path-confined swap-only provider). The stand-in answers it
  (`FAKE_OPENCODE_KEY`); recipe-check's `opencode` selection adds the path leak check and a 0-refusal Locked try.
- **Is it current?** (owner: "record the latest version and how old it is and is it current"). MEASURED: the host checks
  every agent's latest release hourly while it runs (`HostCore.refreshAgentVersions` → `AgentVersions.refresh`, the same
  cache as a preparation's) and, once per new latest, when it came out and npm's deprecation (`NpmRegistry.releaseInfo`:
  npm's full document, or a manifest archive's Last-Modified) → agent-versions.json (`latestReleased`,
  `latestDeprecated`, `infoVersion`). `AgentCurrency` reads it (never the network): active ≤ 90 days, quiet > 90, stale >
  180, deprecated wins, "not checked yet" before a check. RECORDED: `lifecycle` on a recipe or known entry
  (`AgentLifecycle`: current | superseded `by` | retired | discontinued, note, source, checked — `by` must name a recipe or
  known id). Shown in `doz search` (a second line; a superseded hit brings its replacement), `doz try`'s list (and a note
  before a superseded try), the Quick try cards (`WebTryCatalog.Agent.latest/standing`, superseded last), the index
  (`Entry.lifecycle`, `Entry.latest`), the manual (26). `make agent-currency` (`Scripts/agent-currency.py`) is the
  people's report → `profiles/currency.json`, with TODO lines (a new release → re-profile; deprecated/archived → review).
- **The ingredient audit** (655, 617.B3; RECIPE-FORMAT.md "The ingredient audit"): `make recipe-audit [RECIPES=] [PROPOSE=1]`
  (`Scripts/recipe_audit.py`, Python 3.9 stdlib, read-only, no key, no VM) — per published recipe one row per ingredient
  (`pin`, `requirements`, `extras[N]`, `latest`) plus the shared ones (`base:*` digests, `runtime:node22/24/python`,
  `native:claude-code`, read from `BaseCatalogue.swift` by regex — the unit tests read the real file), each
  `ok|changed|behind|gone|unchecked` → `profiles/audit.json` (COMMITTED like currency.json; written only for the published
  set; `AgentProfileTests` skips it). `latest` is currency.json's data, never a second lookup — run `make agent-currency`
  first. Only a 404/410 is `gone`; network trouble is `unchecked`; exit 1 on `changed`/`gone`. All I/O goes through ONE
  `Net` object so the decisions are pure; `Tests/Scripts/test_recipe_audit.py` (fixtures, sockets refused) runs in `make
  test` via `RecipeAuditScriptTests` and alone as `make test-recipe-audit`. `PROPOSE=1` rewrites a behind, non-built-in,
  non-pypi recipe's YAML pin line by line (`rewrite_pin`: each key exactly once, else refused), verified against a
  download (`Mismatch` = an alarm, exit 1), then `make recipes` — never commits; the proposal still needs `make
  recipe-check` + `make profile-agents`. Nightly in the Recipes workflow (job summary + the `recipe-audit` artefact);
  the workflow token stays `contents: read`, it opens no PR and pushes nothing — `Scripts/audit.sh` 4c fails any
  workflow with a write permission, a `git push` or `gh pr create`.
- **Other AI tools are recipes too** (617, RT list; the manual's 28): same shape, same rules. Two install kinds for them,
  both pinned-only (`AgentRecipe.pinnedOnlyKinds`: nothing looked up, `latest` = the pin, `AgentVersions.refreshPackage`
  returns early): `release-binary` (one program from a release download, `{version}` in the url, tar.gz/zip/raw by the
  url's end, sha512-checked) and `pypi` (Dozable's own Python — `PythonRuntime`, python-build-standalone 3.13 glibc,
  sha256-pinned, /opt/python — a venv at /opt/<id>/venv holding EXACTLY `install.requirements`, every line
  `name==version --hash=sha256:…`, pip `--require-hashes --no-deps`, the package's own file also against the sha512
  integrity; the lock is resolved once in a scratch VM). `launch.session: shell` makes the default session `bash -l`
  (a tool that answers and exits: `DozableStore.defaultSession`); a first-run file may be `~/…/.env` (Fabric) — its merge
  code is emitted only into such a recipe's helper, so the other launchers and bake keys are unchanged
  (`ToolRecipeKindsTests`). The VM proofs: workspace `probes/617-*/recipes/` (`setup.sh`, `proof.sh TOOL 'CMD'`, a fake
  provider for xAI + Gemini on 18xxx).
- **Antigravity CLI** (`antigravity`, alias `agy`; Google's lead agent — Gemini CLI is superseded by it): closed source,
  installed by the `manifest-binary` kind — Google's release manifest (`{version, url, sha512}`) read on the Mac
  (`NpmRegistry.manifest`, `parseManifest`: the url must be the recipe's `url` with `{build}`), the release recorded as
  `<version>+<build>` with the sha512 as SRI, checked in the bake; glibc only (`platforms.musl` false). A Gemini API key
  (`modelProvider: gemini` first-run setting + `GEMINI_API_KEY`, the google provider); `AGY_CLI_DISABLE_AUTO_UPDATE=1`;
  `--dangerously-skip-permissions`; the facts as a skill in `~/.agents/skills/doz`.
  A recipe's `excluded` hosts are denied BEFORE the user's rules and
  every permission (Open included), never suggested, never grantable as a site — and are in no permission (validated).
- **Keys read on use** (`SecretSources.swift`, `HostCore+Secrets.swift`): an API-key account (`api-key`, `openai-key`,
  `key`) may carry `AccountRecord.source` — `1password` (op://…), `aws` (an ARN, `#jsonKey`), `command` (absolute
  program + argv) — plus allow-listed `sourceEnv` and `ttlSeconds`. accounts.json holds the REFERENCE only; the value
  never reaches the keychain, a file, a log, a row or an event (`SecretSourcesTests` scans the store). A record without
  `source` is its keychain item, as before. `applyKeySecret` is the ONE place an account's key enters a vault: keychain →
  `setCredential`; a source → `vault.setProvider` (TTL, version = fingerprint(reference+env) + the account's generation
  in `HostCore.secretSourceState`; `refresh`, an edit and an upstream 401 — at most once per 10 s — bump it), prefetched
  when applied and at every session open. The runner (`SecretSources.run`): posix_spawn, argv only (never `sh`), own
  process group killed on timeout (op 20 s, others 10 s), stdin /dev/null, stdout ≤ 8 KiB, stderr ONLY to classify,
  the environment = who/where + `OP_*`/`AWS_*` of the host + the standard PATH + the account's allow-listed variables
  (never a `DOZ_` one). A failure is the vault's notice (the proxy's provider-shaped 401: cause + fix), never another
  key. A command inside the store is refused. **Tests never run the real op/aws**: `DOZ_TEST_OP` / `DOZ_TEST_AWS` are
  the seams; a guarded run without them gets TestSafety's refusal (`DOZ_TEST_REAL_MAC=1` lifts it).
- **Custom keys** (`CustomKey`, provider `custom`, binding `custom:NAME`, swap-only, `doz-custom:NAME` or a source):
  attached by `SandboxConfig.extraKeys` (`--key`, `account use … --extra/--remove-extra`), applied after the main
  account (`applyExtraKeys`; `vault.onStale` handlers chain within one apply — `detachWatcher` resets them), refused
  at attach unless the policy allows every host, withheld with a notice when a policy change denies one (`netPolicy`
  re-applies them). Never a host another binding owns. The dashboard shows source/state and Refresh (`account-refresh`,
  one HostOp) — never adds or changes a source (D7).
- **One set of choices, one plan** (D13): `ChoiceOptions` (LifecycleCommands; `CreateArguments` is its old name) is
  what new, create, up and try take — `--permissions` canonical, `--allow` its alias. The host's read-only op `plan`
  (`CreatePlan.swift`, `CreatePlanner.plan` — pure given `PlanFacts`) is the ONE place a sandbox's defaults are decided
  for new/try (name, workspace; 635: a try's and the First sandbox's network is a new sandbox's — `defaults.permissions`,
  Standard — no longer forced Locked; `make recipe-check` asks for `--network locked` itself, so its "a fresh try is
  refused nothing" stays the strictest check) and what `--dry-run` prints (command, project file, reach from
  `DozableImages.spec`'s policy). A new choice is a ChoiceOptions option + `CreatePlanner.argv` + `yaml` + a pin line.
- **`doz try`** (`TryCommand.swift`, `Try.swift`): 634 — what a try makes is an ORDINARY sandbox (no mark: 617's
  `SandboxConfig.trial`/`trialFolder` are gone, an old doz.json carrying them loads with both ignored); its card comes
  from recipe `auth` only (`TryCard`); its exit prompt ("Leaving NAME — [S]leep / [d]elete / [k]eep running") runs after `AttachClient.attach` — the RETURNING attach: every way out is recorded
  (`endAttach`), the keyboard thread is stopped by a self-pipe (`stoppableRead`) so the prompt gets its first key; keep
  it that way (`KitchenTests.testTheKeyboardThreadIsStoppable`). `run` still exits.
- **The dashboard's Quick try** (`#/try`, `#/try/AGENT` — the wizards' modal over the app, like onboarding (owner: the
  app visible behind the scrim; larger, less margin); Esc/Close return to where it was opened; the app inert; opened from
  the nav's RECIPES section — its Quick try item and the + on its heading; `views/try.js`, `WebTry.swift`). The details pane is
  INFORMATION ONLY (description, versions, tags, what it can reach, the command — what a published recipe page shows);
  **Try** opens the SETUP (`dialog.dlg.try-setup`, `openSetup`): the key, what is not offered, the image, the plan and
  Start. The setup PLANS WITH the account it uses (`POST plan {account}`; the catalog's `usableAccounts` —
  `AgentCredentials.accepts`): a key saved there, one chosen, or — when the provider's default cannot serve the agent
  (pi with the Mac's Claude login) — the first usable one (the owner's "adding a key did not work": it planned with the
  default again). Deleting a try asks with a box to tick (`confirmWithCheck`), never a typed name. The owner's
  redesign (mock 616 quick-try-v2): two panes — search (`core/agent-search.js`: `DirectorySearch`'s matching ported, +
  fuzzy within one word, + its did-you-mean) with pills (Ready · Open source · Current · Headless · Through a gateway,
  AND) and the count over the results (cards | list, `localStorage doz.tryView` in try/catch; superseded, then coming,
  last), the chosen agent on the right; `/` ↑ ↓ Enter; stacked below 760 px with a back control. Search and pills
  redraw IN PLACE (`paint`) so the search box keeps focus; a full `renderModal` only re-reads. The catalog carries each
  agent's mark (`AgentIcons.resolve` → `ResolvedIcon`, drawn by `dom/icons.js mark()` from its path — never fetched,
  no markup parsed) and the pills' facts (`ready`, `openSource`, `headless`, `gateway`, `current`, `version`, `age`).
  `version` is what a try INSTALLS now (`WebTryCatalog.installs` = `AgentVersions.spec(.create)` — never the built-in
  three's frozen fallback pin when the host resolved a latest), `age` only when that version is the latest looked up.
  `probes/617-*/stageE/browser-quick-try.mjs` (screenshots 10–16). `GET
  /api/v1/try` (each recipe agent's try plan + `TryCard` when its provider has no key; the coming ones with why) and
  `POST /api/v1/plan` (strict; the host's read-only `plan` — never a second planner). **The modal draws at once**
  (owner: "a blank modal with a considerable delay"; it waited ~25 s on `GET try`, one `plan` per agent, each re-reading
  every image's readiness): `viewTry` never awaits — the last list (kept for the page's life) or skeleton cards, then
  `GET /api/v1/try/list` (`WebTryCatalog.list`: the recipes alone, no plan, ms), then `GET try` (`plans`: a read-only
  host op planning every agent on ONE reading of the store; an older host gets one `plan` each, six at a time) fills in
  readiness; one read at a time (`tr.reader`, aborted on close), a failure said in the list with Retry, never "nothing
  matches" while loading (`data-try-state` loading|list|full). `TryPlansTests`, `probes/617-*/stageE/browser-try-open-fast.mjs`
  (its control against 16e91ea shows the delay). It makes the try with the
  ORDINARY `create` action (the plan's `create` fields) — browsing prepares NOTHING (owner: no build per recipe looked at; the CLI's `doz try AGENT` still prepares early: an agent named on purpose) — pastes a
  provider's key only through `POST /api/v1/accounts` (kind `key` + provider; sources stay CLI-only). Its page is an
  ordinary sandbox's (634: no try tag, no try bar, no Guide-first). `doz try --ui [AGENT]` (`showDashboardPage`, UICommand.swift — the
  only CoreServices file): starts doz ui detached when none runs; an open page is pointed there by `ui.sock`'s `show
  try[/AGENT]` line (SSE `show`; `WebControl.showPage` and the page both allow ONLY that hash) — a page cannot raise its
  own window, so the CLI activates the default browser through LaunchServices (`bringBrowserForward`, no AppleScript)
  and the page calls `window.focus()` and marks its title "▶ Quick try — …" for 10 s (an installed dashboard app is
  its own window: the title is the cue); with no page open, a browser still signed in for this port
  (`WebSessionStore.keptSessions`) gets the plain `origin/#/try/AGENT`, else a new link with
  `&to=try/AGENT` in its fragment (the bootstrap strips the capability first). The New Sandbox review shows the plan
  for `up` (`project/preview`'s `plan`), and its name follows the agent/base until edited. `WebTryTests`;
  `probes/617-*/stageD/browser-try.mjs` (headless Chrome, scratch profile, screenshots).
- **The start sequence** (617.05, owner: "a confusing flash of activity"; one stable page): from Start the sandbox
  page is there at once (header, action bar, the nav entry) and NOTHING later moves it. 617 (owner, 2026-10-15:
  "fix the delay when clicking the Try button"): `tryCreate` moves in the click's own frame — Start says Starting… (spinner), both
  modals close, the try's page draws its header from the PLAN (`state.pendingTry`, `drawPendingTry`: the same parts as its detail
  will, so nothing moves; the nav lists it) and an indeterminate "Preparing NAME" panel, while the create runs behind it (a 404
  meanwhile is the pending try, not "gone"). A create that fails stays on that page: "NAME was not made", the reason, Back to setup
  (`backToTrySetup`: the setup again with its plan and the error). `probes/617-*/stageE/browser-try-start-latency.mjs` (feedback ≤
  100 ms, modals closed ≤ 300 ms; was 0.9–1.8 s). The terminal area shows, in the same place: (1) while the image is prepared, the build panel
  (`components/start-progress.js`, over `#terminals`): a bar for the whole build — the preparation's own estimate when
  this Mac built the recipe before (`seconds / (seconds + remainingSeconds)`), else a fixed weight per step by its
  wording; a download fills its share by bytes (`transferFraction`); a step past its estimate creeps; monotonic per
  operation (`state.spBar`) — "Step N of M · step · elapsed", the finished steps (`WebOperation.progress`), the raw
  output under "Show details"; a cached image has no preparation, so no bar; a failure keeps the panel (error, log,
  Start again / Dismiss); a running preparation is JOINED (the host's single flight), never started again; the header
  pill says Preparing…, then Booting…; (2) **Console** — terminal mode `console` (ticket `{"mode":"console"}`,
  no session, no size): the bridge's `consoleLoop` streams `data.bootConsole` (what `doz console NAME --follow` shows)
  as inert text, read-only, never an attach; after Home and the build log in the strip, icon `cpu`, no number, never
  persisted; 635: a close box — closed by the person (even during the boot) it stays closed until the next Start;
  otherwise it exists while the VM is powered on (`syncConsoleTab` on each sandbox refresh and on the pending pane's phase);
  (3) the agent's tab: `openPendingTerminal` makes it at Start, laid out but `visibility: hidden` and tab-less
  (`t.pending`), its ticket `quiet` — the bridge then never enters the boot view for it (the old boot view wrote
  `console --follow` into the agent's own pane: vminitd's lines for every exec of the start in Codex's tab, owner's shot
  7625) — and it becomes a tab on its first binary frame: selected, or with `ui.boot_view_on_start` (now default
  FALSE: "stay on Console") an activity dot. No blank terminal, no "Attaching…". What the agent was refused is the
  header's "N denied" menu (`deniedChip` → Review in Network), never a banner. A start from a Sandboxes row is the
  plain start; its page shows Console when opened. `WebTerminalUnitTests` (console + quiet decode);
  `probes/617-*/stageE/browser-start-sequence.mjs` (records the page every 100 ms: nothing moves, the stages in
  order, the bar never back, no vminitd byte on the agent's socket; screenshots 22–25). The panel is never a card and
  is at its final width from its first frame (`.start-progress .sp-box`: the terminal area up to `--build-max`, 1100 px —
  it used to open as a 720 px card until the preparation's data arrived); while it shows, the action bar's status slot
  has no running line (`paintRowOps`: a failure and the result still show there; a Sandboxes row keeps its line). **The build log** (owner: "keep its log as a
  small tab to the LEFT of Console"): the library hands each bake step's WHOLE output (`StepOutputLines`, every line in
  order, inert, head 200 + tail 1800) as `SandboxEvent.stepOutput` — never a `HostEvent` (runPreparation passes it to
  `HostCore.buildOutputSink`, a task-local the preparation sets, so no client, host.log or Activity ever sees it); the
  preparation keeps it with its steps and, when it ends (done or failed), writes `<store>/build-logs/<image>.json`
  (`BuildLogs`, 0600 in 0700, atomic, ≤ 8000 lines; Resources: Dozable's own records) — so it survives a ui and a host
  restart, and a sandbox whose start built nothing shows the log of the build that made its image (none kept → no
  tab). Read by the host op `build-log` (by sandbox; in-process when no host runs) → `GET /api/v1/sandboxes/NAME/build-log`
  (`WebBuildLog`: `BuildLogs.render` — the steps with their times, then each step's output, inert again). The page:
  `syncBuildLogTab` (each sandbox refresh and each preparations event) reads it once into `state.buildLogs` (forgotten,
  and its tab closed, while its image builds); 635 (owner): never opened by itself — Home › Logs › **Build log**
  (`openBuildLog`) opens `openBuildLogTerminal`, a saved-mode, socketless record (`t.buildlog`, like a Boot log; keys never
  wake) as its own tab after the sessions: icon `wrench`, "Build log", a close box, never persisted, kept through shutdown and sleep (`promoteSaved` skips it;
  `isAux` in `core/terminals.js` names the page's own panes). `BuildLogsTests`, the HTTP test.
  **It is the record of how the image was made** (owner: "including all the commands to build and configure"): the
  baker hands out `BakePlan` once per bake (`SandboxEvent.bakePlan`, built by `ImageBaker.plan` — the SAME argv, user and
  environment each exec gets, the checks, the trim, the inputs: base@digest, kernel, guest init, the agent package and
  version/integrity, the bake policy's rules), each check's output is a `stepOutput` too, and nothing a bake DOES changes
  (bake keys, scripts, checks — `RecipePinTests`). `BuildLogDocument` (DozableHost) is the ONE builder: the inputs (early
  steps with "cached"), each step under a display-only plain title (`BuildLogs.title(ofStep:)`/`title(ofCheck:)` —
  never part of a key), its command or script verbatim, every file its script writes (`files(inScript:)`: the
  `cat > PATH <<'TAG'` heredocs), its output; the checks (command, expects, got); the trim. The web tab draws it as
  HTML (`components/build-log.js`, text only), `doz image log IMAGE [--json]` prints `plainText(document)` (host op
  `build-log` with `image`). Every string is scrubbed when the log is saved and again when shown (`BuildLogs.redact`:
  key/token/JWT/placeholder/URL-password/private-key shapes → "[redacted]"; a credential-named variable dropped) and
  made inert (`verbatim`: whole escape sequences and control characters removed, indentation kept). A log kept by an
  earlier build has no plan and says so. Waiting for an operation is
  EVENT-driven (`waitOp`/`waitForOp` settle in `trackOp`): a hidden tab's short timers run once a minute (Chrome's
  intensive throttling — the owner's 68 s pause). `browser-try-twice.mjs` (throttling emulated), `browser-start-progress.mjs`.
- **A try's folder and bridges** (owner, after the demo): a try gets a NEW EMPTY folder under `defaults.projects_dir`
  (`CreatePlanner.tryName` skips a name whose folder holds anything; a given one is a plan problem). 634 — **every
  sandbox's easy delete**: any create records `SandboxConfig.createdFolder` ONLY when Dozable made the folder (never one
  that was there, never for a duplicate); `rm` removes it with the sandbox when empty (host), the CLI asks about one with
  files (`cleanUpCreatedFolder`), the page's Remove… says so (`components/lifecycle.js`). `CreatedFolderTests`, TrySuite 6. The plan's reach says the folder and the bridges (`folder`/`bridge` lines).
  Copying works in every agent: sessions get `GROK_OSC52_SINK=1` while the clipboard bridge is on
  (`HostCore.withClipboardSink` — Grok Build otherwise picks no OSC 52 route in a VM), and `xclip`/`xsel`/`wl-copy`
  are the guest's `doz-copy` shim (`GuestCommand.copyShim`, beside the open shim, stamp — bump it on any change):
  OSC 52 out, reads refused, PRIMARY not sent. `CopyShimTests` runs the real shim.
- **`doz get` / `doz put` / `doz cp`** (`FileCopy.swift`, `HostCore+Copy.swift`, `HostServer.copy`, `FileCommands.swift`):
  the host op `copy` (never a `WebAction`) checks in the guest FIRST (`CopyPaths.getCheckScript`/`putCheckScript` —
  a missing path, a link escaping the folder, an existing destination without `--force`, who may write), answers
  `CopyReady`, then the connection carries `CopyFrame`s (type + length + payload, ≤ 1 MiB) and a tar stream over
  `Sandbox.openGuestStream` (now with `user:` and its stderr) — no new guest→host channel; it ends with `CopyDone`.
  The Mac side is `/usr/bin/tar` (`COPYFILE_DISABLE`, gnutar format, no xattrs/ACLs/flags; `-s …/S` renames —
  uppercase flags SUPPRESS in bsdtar's `-s`, `~` is the match): unpacked into a `mkdtemp` folder BESIDE the
  destination, checked again for escaping links (`LocalCopy.escapingLinks`), then `LocalCopy.place` (a rename;
  `--force`: a file replaces a file, a folder merges) — never into the store (`LocalCopy.inStore`, links resolved).
  In the guest, put runs as the image's user, as root only where it cannot write (`-o`: never the archive's owner).
  Woken/started as `exec`. `FileCopyTests` (the scripts run under /bin/sh), `probes/617-*/stageC/copy-run.sh` (the VM
  proof: an isolated try and busybox).
- **`doz search` and the index** (`DirectorySearch.swift`, `DirectoryIndex.swift`, `Recipes/known.json`): exit codes
  0 / 8 limited / 6 coming / 2 unknown; a known entry whose id a recipe gains is a test failure (the recipe wins).
- **Read model for later stages** (data + tests only so far): `auth.methods`, `gateways[]` (support level per model
  gateway, `how` as templates over `{gateway.endpoint.<id>}`, `{placeholder}`, `{model}`), `capabilityTags` (derived
  from the data; only `headless` is declared). `UsageSchema.agents` must contain every agent id (`RecipeHostTests`).
