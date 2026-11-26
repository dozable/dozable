# canonical/

The canonical workspace models: the **one source** of every workspace file Dozable ships or is measured against. Each
model is a folder `workspace/NAME/` holding

- `NAME.workspace.yaml` — the model itself (a space file; the format line inside is `doz: space/3.1`);
- `INSTRUCTIONS.md` — what it is for and how to use it;
- `README.md` — one paragraph;
- `expected/` (some) — output generated from it, never edited by hand;
- whatever else the file reads beside it (a brief, a defaults file it `extends:`) or, for a template, what doz ships with
  it (`template.json`, `DESCRIPTION.md`).

| Model | What it is |
|---|---|
| `app` | the canonical demo: a manager and four agents fix a flaky test — every major feature in one file |
| `example-space`, `sandbox-team`, `clean-room` | the doz space reference's shared examples (space/3.1), byte for byte, renamed |
| `solo`, `solo-sandbox`, `build-review`, `fix-it`, `video` | the workspace templates doz ships (`TEMPLATES` lists them, in the gallery's order) |

Not here yet: the reference's `state-space` example and a space/3.2 (realms) example — this repository holds no copy of
either. They join when the reference publishes them for Dozable.

## The templates doz ships are generated from here

`Sources/DozableKit/Resources/templates/` is GENERATED from this folder and committed (like `Resources/Web`): edit the
model here, never there, then

```bash
make templates          # Scripts/canonical-templates.sh: canonical/ → Sources/DozableKit/Resources/templates
make templates-check    # fails when what is committed is not exactly what canonical/ makes (make test runs it)
```

`ID.workspace.yaml` ships as `templates/ID/workspace.yaml`, beside `template.json` and `DESCRIPTION.md`; `TEMPLATES`
ships as `templates/ORDER`. A template's file has placeholders (`{{space}}`, `{{owner}}`, `{{folder}}`, `{{manager}}`,
`{{who}}`) that `doz workspace new --template ID` fills.

## expected/

`expected/picture.yaml` is the document `doz ui` hands the renderer for that file — the drawing's input in the
renderer's words (Dozable's places as sandboxes, a fenced place's agents on this Mac). A model that needs none is drawn
from its own text and has no picture. Regenerate after changing a model, and commit:

```bash
make canonical-expected
```

`CanonicalWorkspaceTests` is the drift test for all of it: every model has its files, the shipped templates are this
folder's byte for byte, every model but the templates reads with no error, and each `expected/` is what doz makes now.

## Copies elsewhere

Other projects keep copies pinned to a commit of this repository and their own drift test; re-copy from a commit, never
edit a copy. Dozable's own tests keep the reference's recorded fixtures (with their older `.space.yaml` names) in
`Tests/DozableCLITests/Fixtures/`, pinned to the reference's commits — those are its, not this folder's.
