# Images, bases, agents and resources

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

A bare file name is in `Sources/DozableKit/`.

| Path | What |
|---|---|
| `ImageSpec.swift`, `ImageBaker.swift` | Image specs (base@digest + steps + verify + persist dirs + `journalMiB`), the two agent image specs, the baked-disk cache; base disks (`images/bases/`, flattened once per base key) and clone-tree bakes (`ImageManifest.parent`) |
| `Sources/DozableHost/ImageTree.swift`; `Sources/DozableCLI/TemplateCommands.swift`; `Sources/doz-vmtest/TemplatesSuite.swift` | the lineage (`image-tree`, built from `DiskAccounting`; `doz image ls --tree`, Images › Lineage); templates (`template-create`) and `duplicate` (`Sandbox.duplicate`); `make test-vm-templates` |
| `Sources/DozableHost/Resources.swift`, `HostCore+Resources.swift`; `Sources/DozableCLI/ResourcesCommands.swift`; `Sources/DozableWeb/WebResources.swift`; `Tests/DozableCLITests/ResourcesTests.swift` | the account of everything Dozable uses (the walk, one leaf per entry, the three numbers from `DiskAccounting.exclusive`), refusals, the plan and the deletion; the host ops `resources` / `resources-rm` / `resources-clean` / `resources-kernel`; `doz resources`; the web projection + preview route |
| `Sources/DozableKit/BaseCatalogue.swift`, `OCIImport.swift`; `Sources/DozableHost/BaseImages.swift`, `ContainerTool.swift`, `AppleContainerResources.swift`; `Sources/DozableCLI/BaseCommands.swift`; `Sources/DozableWeb/WebBases.swift`; `Sources/doz-vmtest/BasesSuite.swift` | base × agent images — the catalogue, `ImageChoice` names, `ImageComposer` (+ `recompose` for W28), native Claude Code, pi's Node, digests; the store's base digests and Dockerfiles; Apple's `container` (status/start/install/build) and its storage in Resources; `doz base`, `doz builder`; the bases route and the Dockerfile picker; `make test-cli-bases` |
| `Sources/DozableKit/AgentPermissions.swift`; `Sources/DozableHost/Permissions.swift`; `Sources/DozableCLI/NetPermissionCommands.swift`; `Sources/doz-vmtest/PermissionsSuite.swift` | agent permissions — the catalogue and presets per base, `NetworkPolicy.permissions` (stored by name, `effectiveRules`); edits/report/suggestions/facts; `doz net NAME/allow/deny/permissions`, `--allow`; `make test-cli-permissions` |

## Rules that each cost a bug to learn here

- **Claude Code starts set up and without permission prompts**.
  The claude-code image spec's `claudeLauncher` step installs `~/.local/bin/claude` (first on the
  agent's PATH). It pre-seeds `hasCompletedOnboarding`, the SESSION's placeholder in
  `customApiKeyResponses.approved` (placeholders are minted per session, so a fixed approval can
  never work), `projects[cwd].hasTrustDialogAccepted`, and `settings.json`
  `skipDangerousModePermissionPrompt`, then execs `/usr/local/bin/claude
  --dangerously-skip-permissions`. `DOZ_CLAUDE_PERMISSIONS=ask` and root keep the prompts.
  The script spells the key variable's name apart, because no image spec may name a credential
  (`ImageSpecTests`). These keys were found by diffing the config before and after Claude Code
  2.1.227's own screens, so re-check them when the pin moves — and since 594 images install
  `latest` by default, `make test-cli-onboarding` re-checks the launcher (argv, skill, a session with
  a key) on whatever the registry's latest is.
- **Agent tools:** the dev baseline bakes `fd-find` (+ `/usr/local/bin/fd`) and `ripgrep`, the lab
  `fd` — agents (pi) download them from GitHub otherwise; `api.github.com` stays out of the agent
  preset, `pi.dev` is in it.
- **Agent versions (`AgentVersions.swift`):** `images.claude_code_version` / `images.pi_version`
  = `latest` (default) or exact. `latest` is resolved on the MAC at preparation time
  (`NpmRegistry`: `<registry>/<package>/latest` → version + sha512 integrity, both validated —
  they go into a bake script) and installed at that exact version by `AgentImages.claudeCode(_:)` /
  `pi(_:)`; `ImageSpec.agent` records it, so it is in the bake key. `AgentVersions.spec(purpose:)`
  is synchronous and uses only the store: `.create` → the newest image PREPARED for this build, else
  the newest `usable` one an older doz's recipe made (no waiting), `.prepare` → the version the
  setting names (cached latest, a known exact, else the pin — whether the registry was never asked or did not
  answer: 618, a host that had failed to reach it refused while the CLI with no host planned the pin, so Try and `--dry-run` disagreed). `HostCore.freshen` is the only thing that asks the registry (hourly cache in
  `<store>/agent-versions.json`, 5-min back-off after a failure). Only the
  real host asks (`HostServer` passes `.fromEnvironment()`; `DOZ_TEST_NPM_REGISTRY=offline|URL` for
  tests); in-process hosts and unit tests have `.disabled` and resolve to the pin. Claude Code's own
  updater is off in sessions (`DISABLE_AUTOUPDATER`, `DISABLE_UPDATES` — both honoured by 2.1.227).
- **An image is NEVER rebuilt without the user**.
  W28's bug: "prepared for this build" compared a bake with ITS OWN recorded recipe, so an image rc.1
  baked (no sudo, no lists) still counted after the recipe changed. Now `prepared` = baked by THIS doz's
  recipe for that agent release (`AgentVersions.isCurrentRecipe`: `AgentImages.spec(name, release) ==
  the bake's spec`); `usable` = any bake this build can start. A stale image is USED and SAID:
  `ImageRow.olderRecipe` ("this doz's image adds: sudo, package lists" — `AgentImages.recipeChanges`),
  `available` (a newer release, no background preparation any more), `status`/`standing`; `image ls`
  STATUS, the Images page (badge, Rebuild with the consequences), `doctor` (warn), `SandboxInfo.olderImage`
  (`doz ls`, the sandbox page), create/up/init (`--rebuild` → `CreateOptions.rebuild`: the host
  prepares first; `--use-current`; a TTY asks, default use-current; `--json`: `imageNotice`), the New
  Sandbox form's choice. `doz reset` moves a sandbox to the image a create takes now
  (`moveToCurrentImage`). The facts never claim sudo the guest lacks (checked at session start).
  `DOZ_TEST_OLDER_RECIPE=1` (a TEST seam) bakes rc.1's recipe. Only an image NEVER prepared is
  prepared on first use. `make test-cli-images` checks it.

## Resources

- **Everything adds up.** `Resources.walk` measures the store as `du` does (allocated blocks, `lstat`,
  a hard link once) and `classify` puts EVERY entry on exactly one leaf row; the report's
  `unattributedBytes` = the walk's total − the entries of the rows shown, and must be 0 (the page shows
  it red otherwise; `ResourcesTests` checks it against `/usr/bin/du`). A new kind of file in the store
  gets its leaf in `classify` — never a silent fall-through (anything unknown is `stray:<top name>`).
- **Three numbers**: size (allocated — a clone in full), freed if deleted (`DiskAccounting.exclusive`:
  the blocks only that group's disks reference, plus the allocation of its non-disk files), used by.
  Reuse 587's extents (`F_LOG2PHYS_EXT`); never re-measure differently. "Freed" of a selection is one
  sweep over the whole selection (blocks shared between its items counted once).
- **Deleting never breaks a sandbox**: a sandbox's disks are refused (its page removes it); the
  current kernel and `initfs.ext4` are refused while any sandbox is paused/asleep/hibernated (their
  snapshots need them) or running; any kernel a snapshot needs or a sandbox's spec names
  (`SandboxSpec.kernelPath`, from `kernel.path` at its create), and a current kernel that is not this
  build's pinned one (only the pinned one is fetched again); images being prepared, and the download cache/base disks while any
  is; a stray folder that is a sandbox's workspace or share; anything outside the store; Dozable's own
  records. A parent with a refused part is refused whole.
- **Paths come from ids, never from a request.** Ids are `Resources.isValidID` (and the web's strict
  decoders); `plan` validates them against a FRESH inventory; `execute` removes only the entries its
  own walk classifies under the leaves (top-most first) or the fixed places (restore point dir, screens,
  boots, `content` + `state.json`, `initfs.ext4`); logs are truncated, metrics cleared through
  `MetricsStore.clearHistory` (the running host's own run kept).
- **Serialised with the lifecycle**: `resources-rm`/`-clean` wait (≤ 2 min, a `note` event says why)
  until `diskOpsInFlight` is 0 (every op in `HostCore.diskOps` counts itself in `handle`; a wake by
  use counts in `ensureRunning`), no preparation runs and no sandbox is busy or booting — then read the
  facts, re-check synchronously, and plan + delete with NO suspension point (the actor runs nothing
  else). A dry run is read-only (in-process with no host); a deletion needs the host.
- **Clean up** = `cleanIDs`: cleanable (re-creatable AND unused — an image key no sandbox was created
  from in `resources.clean_unused_days`), deletable, not refused — and never templates, sandboxes,
  points, screens, boots, logs, metrics, the guest init, stray or outside rows, or an image parent. The
  page and the CLI delete exactly the ids the preview showed (`resources-rm`), never a re-computed set.
- **The page measures on arrival, Refresh and an operation's end** — never on a live `changed` event
  (it reads every disk's extent map). The web projection drops `path`; the preview is a CSRF-checked
  POST that changes nothing; there is no delete ROUTE — only the typed actions.
- **"Use this kernel"** writes `kernel.path` (nil = the pinned one): new sandboxes only (the kernel is
  baked into a sandbox's spec at create); refused when `DOZ_KERNEL` sets it.

## Base images: agent × base

- **An image is two choices** (`ImageChoice`): the AGENT (claude-code · pi · none) and the BASE (a
  `BaseCatalogue` id, or `df-<12 hex of the Dockerfile's path>`). Its name is `<base>-<agent>` (`<base>`
  alone for none) — except the three that existed: `claude-code` (Node · Claude Code), `pi` (Node · pi),
  `lab` (Alpine · none, its own `bakePackages` path). Every switch on an image NAME goes through
  `ImageChoice.parse(…)?.agent` (credentials, the default session, the agent prompt, settings sections,
  `withClaudePermissions`) — never `== "claude-code"`.
- **The Node images are byte-identical to before 596** (`BaseImagesTests.test_nodeImagesAreByteIdentical`
  pins their canonical JSON): `ImageComposer` returns `AgentImages.claudeCode/.pi(release, base:)` for
  the catalogue's Node, `ImageSpec.bakeHosts` is nil for them (absent from the canonical JSON), and the
  launcher's `.node` script is the old one. Keep that test green: a key change re-bakes every store.
  678: a launcher change ships at RUN time instead — `AgentImages.launcherRuntimeScript` is written over the
  baked one at every agent session start (`launcherRefreshScript`; onboarding.md, "The environment prompt").
- **Claude Code on a base without Node is its NATIVE build** (`NativeClaudeBuild`: the sha256 of
  linux-arm64 and linux-arm64-musl from `downloads.claude.ai/claude-code-releases/<v>/manifest.json`,
  resolved on the Mac — `AgentVersions.refresh` remembers it per version in agent-versions.json; the pin
  for 2.1.227 is built in), its setup in python3 (`claudeSetupPython` — the same keys as the JS). pi on a
  base without Node: Node's official tarball under /opt/node (`NodeRuntime`, checksum-verified; Alpine:
  apk nodejs), and `/usr/local/bin/pi` puts it first on pi's PATH only. Steps before the baseline run in
  POSIX `sh` on apk/auto bases (Alpine has no bash).
- **Bases are digest-resolved, never followed silently**: `BaseDigests` (`<store>/base-digests.json`)
  asks the tag's registry at most hourly (`freshen`; `DOZ_TEST_BASE_REGISTRY=offline|pinned`), a
  preparation uses the last digest (else the catalogue's pin). A prepared image made from an older digest
  is `ImageRow.baseUpdate` / `BaseRow.updateAvailable` — offered, never rebuilt. The W28 recipe check
  is `ImageComposer.recompose(spec)` (same base, same release) — it works for every pair.
- **A base's language registries join a proxied policy** (`NetworkPolicy.adding(registries:)`, HTTPS,
  appended, preset name kept; locked/open untouched); a bake reaches the spec's `bakeHosts` too
  (`NetworkPolicy.bake(adding:)`).
- **Dockerfiles** (`Dockerfiles`, `<store>/dockerfiles.json`): a create registers it (validated: absolute,
  a file ≤ 1 MiB, not in the store); a sandbox made before its first build holds a placeholder base
  (`doz.local/df-…@sha256:0…`) and its start builds, then `rebindDockerfileImage` re-adopts it with the
  built spec (only with no root disk). A preparation runs `container build -t doz/<base>:latest` then
  `container image save --platform linux/arm64 -o` (1.2.2's `-o type=oci,dest=` fails after exporting),
  `DockerfileImport` → `OCIImport.load` into Dozable's store as `doz.local/<base>@<digest>`; the SAME
  LAYERS keep the previous reference (nothing re-baked — B8). The image's ENV reaches sessions (PATH
  entries ahead of the defaults). "Dockerfile changed — rebuild available" comes from the file's sha256.
- **Apple's `container` is started or installed only because a person asked** (`ContainerTool`):
  `builder-start` = `container system start --enable-kernel-install`, `builder-install` = the pinned signed
  pkg, sha256-checked, `pkgutil --check-signature`, opened in Installer — never sudo. The CLI asks (or
  `--yes`); the page shows what each does before its button. Seams: `DOZ_TEST_CONTAINER` (a fake; a
  non-executable path = not installed), `DOZ_TEST_CONTAINER_INSTALL` (records, never downloads/opens),
  `DOZ_TEST_FILE_PICKER`, `DOZ_TEST_APPLE_CONTAINER_ROOT`. **B9: a Dockerfile build runs OUTSIDE Dozable's
  network policy** — said on the card, by the CLI, and in the preparation's log (`Dockerfiles.outsidePolicyNote`).
- **Apple's storage is shown, never deleted** (`Resources.appleContainerItems`): an `outside:apple-container`
  row (its data folder by part, the program, Dozable's own `doz/…` images), not in Dozable's total or the
  unattributed check, no checkbox on the page.
- **Never rebuild a running test's `doz` in place**: a long VM run (the matrix) runs from a COPY of the
  binary and its bundles — `make cli` under a running host is an earlier incident.

## Agent permissions

- **A proxied policy is permissions, stored BY NAME** (`NetworkPolicy.permissions`; the catalogue is
  `AgentPermissions.all` in the library). Evaluation uses `effectiveRules` (the user's own `rules` FIRST,
  so they win, then the hosts of each permission as THIS build defines them) and `effectiveDefault`
  (`web` → allow). Anything that reads a policy's hosts must use those two, never `rules` /
  `defaultAction` directly — a permissions policy's `rules` are only the user's sites. A pre-597 policy
  (`permissions == nil`) evaluates exactly as before; `PermissionPolicy.inferred` shows it as
  permissions and its first permission edit converts it (`asPermissions`: what it allowed stays allowed).
- **Presets `locked` / `agent` (Standard) / `open` are sets of permissions per base**
  (`AgentPermissions.preset(_:base:)`, Standard = model, update, `install:system` + the base's
  ecosystems, github, error-reports); `bake` stays a policy of RULES (preparation). `DozableImages.spec`
  gives a new proxied sandbox: the form's exact `permissions`, else the preset named by `--network` or
  the image's network setting (resolved `source != .default` — `settings.string` returns defaults too),
  else `defaults.permissions`; `--allow` words on top (`site:HOST` → a user rule).
- **Claude Code's hosts must keep working** under Standard: api/statsig (model), downloads.claude.ai +
  pi.dev + the agents' own npm packages by path (update), the Datadog intakes (error-reports), GitHub
  (github). `AgentPermissionsTests.testClaudeCodesOwnHostsBelongToItsPermissionsAndKeepWorking` and
  `make test-cli-permissions` (real curls from the guest) pin it. "Update itself"'s npm rule is
  path-conditioned (the proxy decrypts) — dropped when `install:node` allows npm whole.
- `model` cannot be revoked; `web` / `open` warn and ask (CLI `confirm`, page `confirmWeb`). Sign in is
  off in Standard; the strict sign-in block still applies on top when it is on.
- Edits: `HostRequest.grant/revoke` on `net-policy` (`PermissionPolicy.edited`, pure — the web preview
  uses it too); the checklist + suggestions from the log are `net-permissions` (read-only,
  `PermissionReport`). The facts block's `network.permissions` / `network.description` list them in
  plain words (`PermissionPolicy.facts`).
