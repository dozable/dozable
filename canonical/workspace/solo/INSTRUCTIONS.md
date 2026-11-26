# solo — instructions

**What it is for.** A shipped workspace template, "One agent": the simplest workspace: one Claude Code agent, fenced on this Mac, works in the folder, and you talk to it in the room. The starting point for a person who wants one agent and nothing else.

**How to use it.**

- Make one: `doz workspace new [NAME] --template solo` (or the dashboard's New workspace gallery). doz fills
  the placeholders and writes `NAME.workspace.yaml` and `DESCRIPTION.md` into `~/doz-workspaces/NAME/` (your
  `defaults.projects_dir`), then plans and sets it up. `--dry-run` shows the plan and writes nothing.
- Look at what doz carries: `doz workspace templates solo --files`.

**Placeholders.** The file is not a space file until it is rendered: `{{space}}` (the workspace's name), `{{owner}}`
(you, as chat knows you), `{{folder}}` (the work folder) and `{{who}}` (the name's chat-safe prefix for each
agent, so two workspaces from one template never share an agent's name). Each value is written JSON-quoted.

**Files.** `solo.workspace.yaml` (the model, with placeholders), `template.json` (what the gallery reads — the page
never parses YAML), `DESCRIPTION.md` (posted in the room when it starts; `--brief` replaces it). These three are
GENERATED into `Sources/DozableKit/Resources/templates/solo/` by `make templates` — edit them here, never there.

**Rules every template keeps.** No agent is ever unfenced (a built-in never acts as you); a manager is always one of
your bots (`external: { bot: … }`), never owned.
