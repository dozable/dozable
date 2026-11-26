# clean-room — instructions

**What it is for.** The opposite end from `app`: a run that keeps nothing. It is the reference for `archive: off`
(what goes with no copy is named in the plan, the summary and the confirmation), for `transcripts: discard`, for a
scratch folder made for the run, and for a brief given as text rather than a file.

**How to use it.**

- `doz workspace plan -f clean-room.workspace.yaml` — every step, and the summary that names what is deleted with no
  copy at `down`.
- `doz space config clean-room.workspace.yaml` — the file as read (it extends nothing).
- Run it with `doz workspace up -f clean-room.workspace.yaml`, then `doz workspace down clean-room`: the scratch folder,
  the room and the transcripts go; nothing is kept.

**Files.** `clean-room.workspace.yaml` only — it needs no brief file and no defaults file.

**Where it comes from.** The reference's `fixtures-for-dozable/v3.1/spaces/`, byte for byte (pinned for Dozable's tests
in `Tests/DozableCLITests/Fixtures/space31-reference/`); only the file's name changed.
