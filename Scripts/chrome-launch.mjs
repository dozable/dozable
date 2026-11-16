// spawnChrome(chrome, args, options, scratch) — spawn a headless Google Chrome as its OWN responsible process.
//
// A Chrome started from a terminal's process tree is charged, for macOS's privacy checks, to the app at the top of
// that tree (Terminal, an IDE, Claude Code): Chrome touching its own bundle and its own group container then reads as
// "<app> was prevented from modifying apps on your Mac" / "<app> tried to access data from other apps" — a notice on
// the person's screen at every run, even with a scratch profile (2026-11-16: the system log named Google Chrome as the
// accessing process each time). Scripts/own-responsibility.c disclaims that and execs Chrome in place (same pid, same
// pipes), so a kill still reaches Chrome. It is built once into `scratch` with `cc`; without a compiler Chrome is
// started as before and a line says the notices may appear.
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SOURCE = join(dirname(fileURLToPath(import.meta.url)), 'own-responsibility.c');

export function ownResponsibilityLauncher(scratch) {
  mkdirSync(scratch, { recursive: true });
  const out = join(scratch, 'own-responsibility');
  if (existsSync(out) && statSync(out).mtimeMs >= statSync(SOURCE).mtimeMs) return out;
  const r = spawnSync('cc', ['-O2', '-o', out, SOURCE], { encoding: 'utf8' });
  if (r.status === 0 && existsSync(out)) return out;
  console.error('chrome-launch: could not build own-responsibility (' + ((r.stderr || r.error?.message || '').trim().split('\n')[0]) +
    ') — starting Chrome directly; macOS may show a privacy notice charged to this terminal');
  return null;
}

export function spawnChrome(chrome, args, options, scratch) {
  const launcher = ownResponsibilityLauncher(scratch);
  return launcher ? spawn(launcher, [chrome, ...args], options) : spawn(chrome, args, options);
}
