import DozableTUI

/// 594 (D10) — questions on the terminal: `doz onboard` and `doz init` ask on a TTY, with the recommended answer
/// pre-selected (Enter accepts it); `--yes` accepts every default; not a terminal or `--json` never asks. 637: the
/// asking itself is DozableTUI's `Prompter` (typed answers, as before, unless a caller asks for `keys:` — `doz onboard`
/// does: arrow keys on a terminal).
typealias Asker = Prompter
