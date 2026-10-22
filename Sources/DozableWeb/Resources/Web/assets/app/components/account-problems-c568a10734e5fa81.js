// components/account-problems — what is wrong with the keys and sign-ins, as data (Accounts & keys' "Needs you" and the
// sidebar's badge read the same list). A problem: a key its provider refused or Dozable cannot read, or a Mac login that
// is signed out / expired while a sandbox relies on it. Keys stored twice (one fingerprint) that both
// fail are ONE problem. Worst first: the more sandboxes it breaks the earlier, then a failing key before a login, then
// by name. Only what the accounts list and the overview already say — no request of its own.

/// The provider a row's key belongs to: a `key` its own (custom included); OpenAI's kinds; else Anthropic's.
export function providerOf(x) {
  if (x.kind === 'key') return x.provider || 'custom';
  if (['openai-key', 'chatgpt', 'codex-mac'].includes(x.kind)) return 'openai';
  return 'anthropic';
}
export const isLogin = (x) => x.kind === 'mac' || x.kind === 'codex-mac';
export const FAILING = ['rejected', 'unavailable', 'missing', 'locked'];
export const isFailing = (x) => FAILING.includes(x.state);
/// A login that cannot give a sandbox a token now.
export const loginDown = (x) => isLogin(x) && !['ok', 'expires-soon'].includes(x.state);
/// A sandbox whose network reaches no model provider needs no key (NAT and none: nothing goes through the proxy).
export const needsNoKey = (s) => s.network === 'nat' || s.network === 'none';

/// The problems, worst first. Each: {tone: 'bad'|'warn', row, twins: [rows], affected: [sandbox names]}.
/// `sandboxes`: the overview's rows (to leave out the ones that need no key).
export function accountProblems(a, sandboxes) {
  const rows = (a && a.accounts) || [];
  const noKey = new Set((sandboxes || []).filter(needsNoKey).map((s) => s.name));
  const out = [], seen = new Set();
  for (const x of rows) {
    const id = x.name + '|' + x.kind;
    if (seen.has(id)) continue;
    let p = null;
    if (loginDown(x)) {
      // A problem only while a sandbox relies on it: a new store's Anthropic default is this Mac's login, and a Mac that
      // never signs in to Claude Code (or Codex) must not be told so on every visit.
      if ((x.usedBy || []).some((n) => !noKey.has(n))) p = { tone: 'warn', row: x, twins: [] };
    } else if (!isLogin(x) && isFailing(x)) {
      const twins = x.fingerprint ? rows.filter((y) => y !== x && y.fingerprint === x.fingerprint && !isLogin(y) && isFailing(y)) : [];
      for (const t of twins) seen.add(t.name + '|' + t.kind);
      p = { tone: 'bad', row: x, twins };
    }
    if (!p) continue;
    seen.add(id);
    const used = [x, ...p.twins].flatMap((y) => y.usedBy || []);
    p.affected = [...new Set(used)].filter((n) => !noKey.has(n)).sort();
    out.push(p);
  }
  return out.sort((l, r) => (r.affected.length - l.affected.length) || ((l.tone === 'bad' ? 0 : 1) - (r.tone === 'bad' ? 0 : 1))
    || l.row.name.localeCompare(r.row.name));
}

/// How many problems break a sandbox's next session (the sidebar's badge).
export function brokenCount(a, sandboxes) {
  return accountProblems(a, sandboxes).filter((p) => p.affected.length).length;
}
