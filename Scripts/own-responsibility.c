// own-responsibility PROGRAM [ARGS…] — runs PROGRAM IN PLACE of itself (same pid, same descriptors) as its OWN
// responsible process for macOS's privacy checks (TCC).
//
// Why: macOS charges a privacy request to the "responsible" process — the app at the top of the tree that started it
// (Terminal, an IDE, Claude Code). A headless Google Chrome started by a script touches its own app bundle and its own
// group container; charged to the terminal app, that reads as "<app> was prevented from modifying apps on your Mac" and
// "<app> tried to access data from other apps" — a notice on the person's screen each run (seen 2026-11-16, both
// charged to Claude Code, from a headless Chrome with a scratch profile). Disclaimed, Chrome is responsible for itself:
// its own bundle and data are its own, and nothing is asked.
//
// `responsibility_spawnattrs_setdisclaim` is libsystem's (the same call Chromium, LLDB and Terminal use); it is not in a
// public header, so it is declared here. POSIX_SPAWN_SETEXEC makes the spawn an exec: the caller keeps the pid it
// started (a kill reaches Chrome itself) and the pipes it handed over.
//
// Built by Scripts/chrome-launch.mjs into the caller's scratch folder (`cc`, Xcode's command-line tools). No output of
// its own unless the exec fails (exit 127).
#include <spawn.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>

extern char **environ;
int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim);

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: own-responsibility PROGRAM [ARGS…]\n"); return 64; }
    posix_spawnattr_t attrs;
    if (posix_spawnattr_init(&attrs) != 0) { perror("own-responsibility: posix_spawnattr_init"); return 127; }
    if (posix_spawnattr_setflags(&attrs, POSIX_SPAWN_SETEXEC) != 0) { perror("own-responsibility: setflags"); return 127; }
    if (responsibility_spawnattrs_setdisclaim(&attrs, 1) != 0) { perror("own-responsibility: disclaim"); return 127; }
    pid_t pid;
    int rc = posix_spawn(&pid, argv[1], NULL, &attrs, &argv[1], environ);
    fprintf(stderr, "own-responsibility: %s: %s\n", argv[1], strerror(rc));
    return 127;
}
