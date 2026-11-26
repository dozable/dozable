# sandbox-team — instructions

**What it is for.** A builder and a tester share one owned Sandbox (`build-vm`, its disk kept between runs) — the folder
is all of the Mac they see — while a reviewer, fenced on this Mac and read-only, joins only with `--profile review`; an
existing sandbox's agent is adopted and an existing room only referenced. It is the reference for a shared VM, for
profiles and for drawing a Sandbox with several agents in it beside a place on the Mac.

**How to use it.**

- `doz space config sandbox-team.workspace.yaml` — the merge with `my_doz_workspace_defaults.yaml`, each value's source.
- `doz workspace plan -f sandbox-team.workspace.yaml` — what `up` would make: the Sandbox, the room, each agent;
  add `--profile review` to include the reviewer.
- The brief is `BRIEF.md` beside the file; there is none here, so a plan says it is missing. Write one to run it.
- Stand-in names (owner `ada`, host `host-a`): change them to yours before an `up`.

**Files.** `sandbox-team.workspace.yaml` and the defaults file it extends, `my_doz_workspace_defaults.yaml`.

**Where it comes from.** The reference's `fixtures-for-dozable/v3.1/spaces/`, byte for byte (pinned for Dozable's tests
in `Tests/DozableCLITests/Fixtures/space31-reference/`); only the file's name changed.
