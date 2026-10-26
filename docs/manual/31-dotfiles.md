# Your dotfiles

A new sandbox has a stock shell: no aliases, no prompt of yours, no editor settings. Point Dozable at your
**dotfiles** — a git repository of them, yours or someone else's — and every new sandbox gets them at its first
start, so a shell in any sandbox feels like yours.

## Setting it up

One setting, `sandbox.dotfiles`, for every new sandbox:

```bash
doz config set sandbox.dotfiles https://github.com/you/dotfiles   # a repository over https
doz config set sandbox.dotfiles ~/dotfiles                        # or a folder on this Mac that is a git repository
doz config unset sandbox.dotfiles                                 # none again (the default)
```

A sandbox can have its own instead: `doz new --dotfiles PATH|URL` (also `doz create`, `doz try` and `doz up`),
`dotfiles:` in its `doz_project.yaml`, or `--dotfiles none` for a sandbox without them. In the dashboard, the
**Settings** page takes a repository's URL (a folder on your Mac is set from the Mac, with `doz config set`); New
sandbox's review shows the repository, the commit it will get and what will run.

Nothing changes for anyone who does not set it.

## What happens

- **Fetched on your Mac.** Dozable fetches the repository with your Mac's own `git`, so a private repository works
  with the login your Mac already has — and that login never reaches the sandbox. A sandbox gets the commit its
  repository was at when it was made; that commit is recorded with the sandbox.
- **Only the files go in** — copied in from the Mac at the first start, into `~/.local/share/doz/dotfiles`. The
  sandbox's network is not used. (A folder on your Mac: its last commit — changes not committed are not included.)
- **Applied as the sandbox's user**, the way GitHub Codespaces does it:
  - if the repository has an install script, it runs — the first of `install.sh`, `install`, `bootstrap.sh`,
    `bootstrap`, `script/bootstrap`, `setup.sh`, `setup`, `script/setup` — from the files' folder, for at most 5
    minutes. Its output is in the boot log (`doz console NAME --steps`, the sandbox's Boot logs) and all of it in
    `~/.local/share/doz/dotfiles.log`. A script that fails is said; the sandbox still starts;
  - with no script, every dotfile and dot-folder at the top of the repository is **linked** into your home
    (`~/.bashrc` → the repository's `.bashrc`).
- **Once.** The sandbox remembers the commit it applied: later starts and wakes do nothing. A reset (which gives the
  sandbox a fresh system disk) applies them again at its next start.

## What is never touched

The link pass never replaces a file that is already there — yours stays, and `doz dotfiles NAME` lists it as kept.
The one exception is the image's own stock copy: a file that is byte-for-byte the one in `/etc/skel` (Debian's stock
`.bashrc` and `.profile`) is replaced by yours and kept beside it as `.bashrc.doz-stock`.

It never touches **Dozable's own** files either: the agents' settings and state (`~/.claude`, `~/.claude.json`,
`~/.codex`, `~/.pi`, `~/.config/opencode`, `~/.agents`, each tool's own folders), the agents' launchers in
`~/.local/bin`, and Dozable's state (`~/.local/state/doz`). A folder that holds one of them — `.config`, `.local` —
is linked entry by entry instead (`~/.config/nvim`, `~/.local/bin/mytool`), never as a whole. The repository's own
files (`.git`, `.github`, `.gitignore`) are not linked, and submodules are not fetched.

An install script is different: it is code you chose, and it runs as the sandbox's user, with the sandbox's network
policy — Dozable does not police what it does.

## Trust

Dotfiles are code that runs in the sandbox. So the first time a repository's commit would be applied, `doz` says what
will run and asks — once per repository and commit:

```
[doz] dotfiles: https://github.com/you/dotfiles at 3f2a9c41d0be (bash: aliases) — code that runs in the sandbox, as its user, at its first start:
  9 dotfiles linked into ~ — never over a file that is there, never over Dozable's own: .bashrc, .gitconfig, .vimrc, …
  the files are copied in from this Mac; no credential of yours enters the sandbox
Apply these dotfiles in the sandbox? [y/N]
```

Without a terminal (a script, `--json` in a pipe) it refuses and names the command that says yes ahead:

```bash
doz dotfiles trust https://github.com/you/dotfiles --commit 3f2a9c41d0be…   # this commit
doz dotfiles trust                                                         # the setting's repository, at its head now
```

## Seeing and updating them

```bash
doz dotfiles my-app            # the repository, the commit, what it does, how the last run went
doz dotfiles my-app --update   # move to the newest commit and apply it — now when it runs, else at its next start or wake
```

`--update` asks again for a commit you have not said yes to. With a repository that has no script, a file the new
commit removed loses its link, and a new one is linked. A sandbox that had no dotfiles takes the setting's with
`--update`.

The sandbox's page shows its dotfiles on its Home (**Folder**: the repository, the commit, how the last run went),
and the agent is told about them in its facts ("Dotfiles: the user's dotfiles … are applied in this home").

## Not covered

Dozable runs your repository's own script — it has no special support for chezmoi, stow or yadm beyond that (your
`install.sh` can call them). Secrets do not belong in dotfiles: anything in the repository is copied into every sandbox.
