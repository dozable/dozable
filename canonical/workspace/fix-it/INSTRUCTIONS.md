# fix-it — instructions

**What it is for.** A shipped workspace template, "Fix-it team": the canonical demo (`app`) made generic: your bot manages; a builder and a tester share one Sandbox; a reviewer reads, fenced on this Mac; a helper keeps notes. The room and its history carry over between runs; npm is reachable.

**How to use it.**

- Make one: `doz workspace new [NAME] --template fix-it --manager BOT` (or the dashboard's New workspace gallery). doz fills
  the placeholders and writes `NAME.workspace.yaml` and `DESCRIPTION.md` into `~/doz-workspaces/NAME/` (your
  `defaults.projects_dir`), then plans and sets it up. `--dry-run` shows the plan and writes nothing.
- Look at what doz carries: `doz workspace templates fix-it --files`.

**Placeholders.** The file is not a space file until it is rendered: `{{space}}` (the workspace's name), `{{owner}}`
(you, as chat knows you), `{{folder}}` (the work folder), `{{manager}}` (the bot you name with `--manager`) and `{{who}}` (the name's chat-safe prefix for each
agent, so two workspaces from one template never share an agent's name). Each value is written JSON-quoted.

**Files.** `fix-it.workspace.yaml` (the model, with placeholders), `template.json` (what the gallery reads — the page
never parses YAML), `DESCRIPTION.md` (posted in the room when it starts; `--brief` replaces it). These three are
GENERATED into `Sources/DozableKit/Resources/templates/fix-it/` by `make templates` — edit them here, never there.

**Rules every template keeps.** No agent is ever unfenced (a built-in never acts as you); a manager is always one of
your bots (`external: { bot: … }`), never owned.
