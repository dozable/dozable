# example-space — instructions

**What it is for.** The smallest workspace that still uses `extends:` and an external manager: a reference for how a
defaults file merges into a space file, how a risky setting (unfenced, bypass) is traced to the file and line that set
it, and how an external bot and an external folder are only checked, never made or removed.

**How to use it.**

- `doz space config example-space.workspace.yaml` — the merge: the defaults file first, then this file; each value set
  elsewhere is annotated with its file and line, and the risky settings are listed with where they come from.
- `doz workspace plan -f example-space.workspace.yaml` — the steps `up` would run; changes nothing.
- It names the folder `~/work/example-repo`, the host `host-a` and the bot `manager`: stand-in names. To run it, change
  them to yours — and note that `up` asks you on a terminal to confirm the unfenced worker, every time.

**Files.** `example-space.workspace.yaml`, the defaults file `my_doz_workspace_defaults.yaml` it extends (the same file
`sandbox-team` extends). Its brief points two folders up (`../../BRIEF.md`), as in the reference's own tree: here there
is no such file, so a plan reports the brief as missing.

**Where it comes from.** The reference's `fixtures-for-dozable/v3.1/spaces/`, byte for byte (the copy Dozable's tests
pin is `Tests/DozableCLITests/Fixtures/space31-reference/`); only the file's name changed.
