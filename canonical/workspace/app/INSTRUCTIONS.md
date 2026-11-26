# app — instructions

**What it is for.** The demo every picture, post and walkthrough of a whole workspace starts from. It uses every part
of the format Dozable ships today: a brief with references, an external main folder and a folder fresh each run, two
places (a Sandbox shared by two workers, a fenced place on this Mac), a manager that is one of your Agents / Bots, a
read-only reviewer with a narrower network, a room that persists, the feeds, the permissions it asks for and the
drawing's layout pins (`x-editor`).

**How to use it.**

- Look without changing anything: `doz workspace plan -f app.workspace.yaml` (no daemon is started).
- See it merged, each value with its file and line: `doz space config app.workspace.yaml`.
- Draw it: open it in `doz ui`'s space editor, or hand `expected/picture.yaml` to the renderer — that is the document
  the dashboard gives the renderer for this file (`x-dozable.places` as sandboxes, a fenced place's agents on this Mac).
- To run it for real it needs `~/code/app` (the main folder) and a bot called `mira` (`doz bot add mira`); `up` asks
  nothing — no agent here is unfenced.

**Files.** `app.workspace.yaml` (the model), `BRIEF.md` (its brief), `README.md` (this folder's summary, and the
brief's reference), `expected/picture.yaml` (generated — see `canonical/README.md`).

**Keep in mind.** Every key in it is one Dozable reads today; a change that adds a feature to the demo goes here first,
then into the `fix-it` template (the same team made generic) when the template should follow.
