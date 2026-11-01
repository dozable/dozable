# The terminal — DozableTUI

Part of the engineering guide; the cross-cutting rules are in [CLAUDE.md](../../CLAUDE.md).

## Where its code lives

| Path | What |
|---|---|
| `Sources/DozableTUI/` | 637: what the CLI draws on a terminal — `Terminal` (the colour decision), `Style` (semantic tones, the ONE place SGR lives), `Components`, `Keys` (the input seam, raw mode, key decoding), `Prompter` (the questions; `Asker` is its alias); `Tests/DozableCLITests/TUITests.swift` |

## The terminal — DozableTUI, colour on one switch

637 (owner: "a library of reusable tui components that the colour effects are based on; colour should be able to be
turned off with a flag and setting"). `Sources/DozableTUI` — Foundation + Darwin only (the audit holds it), so the host
may use it too.

- **Colour is decided ONCE per process**: `GlobalOptions.validate()` (ArgumentParser validates an option group as it
  decodes it) calls `Terminal.configure(colour:json:quiet:)`. The mode: `--no-color` / `--color auto|always|never` >
  `$DOZ_COLOR` > the setting `ui.color` > `auto` (`GlobalOptions.colourMode`, through `DozableSettings.resolve`). Then
  `Terminal.decide`: `never` → off; `always` → on, even off a tty; `--json` or `-q` → off; `NO_COLOR` (any value) → off;
  `auto` → on only when the fd is a tty and `TERM` isn't `dumb`. `Terminal.current.colour` is stdout's;
  `colour(fd: STDERR_FILENO)` is stderr's (progress, attach's notices). Tests replace `Terminal.current` (the seam).
- **Never a raw colour at a call site**: `Style.ok("✓")`, `Style.dim(…)`, `Style.code(…)` — semantic `Tone`s; SGR codes
  live in `Style.swift` only (16 basic colours + attributes). Colour never carries meaning alone: the glyphs (✓ ! ✕ · …)
  are text, and colour off renders the same words (`TUITests` checks `Style.strip(on) == off`).
- **Components render to a String** (`render(width:colour:)`; `render()` for this process's stdout): `StepHeader`, `Rule`,
  `Section`, `Spacer`, `StatusLine` (a long detail wraps under its own column), `KeyValues`, `Note`, `Command` (no `$ `
  — it pastes as is). A line a script or a VM suite matches stays unwrapped (`StatusLine` without `detail`).
- **Questions: `Prompter`** (`Asker` in DozableCLI is a typealias; `Asker(yes:json:)` behaves exactly as before — typed).
  `keys: true` (only `doz onboard` asks for it) = the key-driven components on a terminal: `choice`/`choose` (↑/↓, j/k,
  Enter; a number picks at once unless it could start a longer one), `yesNo` (y/n, ←/→, Enter), `text` (default shown
  dim, Enter takes it, Tab edits it, a `valid` refusal shown under the field and asked again in place), `checklist`
  (Space ticks). Drawn by `LiveBlock` (every line fitted to one row, so the block's height is its line count; redraw =
  up N, `\r\e[J`). Raw mode (`RawMode`): ISIG off, so Ctrl-C is a byte → the mode restored, then SIGINT re-raised
  (`onInterrupt`); TERM/HUP/QUIT and `atexit` restore it too. **The typed fallback** is the old Asker's code, unchanged:
  used when keys aren't asked for or raw mode can't be had, and by `doz onboard` when stdout is a pipe (stdin a tty).
  `make test-cli-projectwizard` and `TrySuite` drive typed questions through `script(1)` — keep them typed.
- **The input seam** is `PromptChannel`: `TTYChannel` (/dev/tty, never stdin) or `ScriptedChannel` (tests inject bytes:
  `\u{1B}[B`, `\r`, ` `, digits). Both paths read through it.
- **Colour sites on the switch**: onboard, the progress view's animated/plain choice (`progressMode` — animated needs
  stderr's colour; `Progress` keeps `color: true` because animated implies it), `doz console --boot` (`BootLogs.render`),
  `doz ui share`'s QR, attach's dim notices. NOT moved (not colour): attach's reverse-video status bar, the terminal
  mode restore and title/clear sequences (`TerminalModes`, `AttachClient`), the copy meter's line erase.
