// views/accounts — Accounts & keys, around the four tasks (617.B9's chosen "Full" direction, re-cut in 641 after the
// dashboard review; owner: "the Accounts & Keys ui page is horrible and needs a redesign. Confusing and clunky" … "limit
// the table widths to a max"). The whole page is ONE 960 px column, the title and Add a key included.
//
// 1. Fix a failing key — "Needs you": one block, a line per problem, worst first (it breaks a sandbox's next session),
//    keys stored twice merged into one line, the fix as the line's one button (Copy `claude`, Add it again…, Read
//    again, Replace…) and ⋯. Nothing wrong: "Every key works". (components/account-problems.js — the sidebar's badge
//    counts the same lines that name a sandbox.)
// 2. See which key a sandbox uses — the Sandboxes view: Key, How it gets it, Status; a sandbox whose network reaches no
//    model provider "Not needed"; Change in place (a select of the keys its tool accepts, the default, No key — the
//    existing account-use action, from its next session).
// 3. Change a default — the Keys view: per provider a heading line over ONE table (Key · one Status · Used by on one
//    line, "… +N" past it · a Default tick · the one verb + ⋯: Set default, Check again, Read again, Edit…, Details,
//    Remove…); Anthropic's "No default" is the table's last row; the Mac login's keep-alive under it.
//    Edit… (every key but a login and a ChatGPT sign-in; owner: "add a way to edit key details") is ONE step: the Name
//    (`account-edit`: everything that names the key goes with it), a setup token's Plan (the same action), and — for a
//    key Dozable keeps in the keychain itself — "Replace the key", optional (POST /api/v1/accounts with `replace` and
//    `edit`: a key that WORKS may be replaced too). A key read from 1Password / AWS / a command, a custom key or a
//    keychain item the person named: the name only, and the `doz account add … --force` line for the rest.
// 4. Add a key for a tool — step 1 asks "Which tool is it for — or which provider?" and answers a tool with the providers
//    it can use and the keys already there; a failing key is replaced IN PLACE (`replace: true` — the host's add with
//    force; refused by the server for a key that works). A pasted key follows ui.allow_secret_entry and the secret rules
//    (a masked field, emptied before the one POST /api/v1/accounts, never echoed); 1Password / AWS / a command / a custom
//    key / a ChatGPT sign-in: the exact `doz account add` line to copy.
// Find filters both views. Only what the host already exposes; every action one HostOp.
import { h } from '../dom/h.js';
import { icon, phaseMark } from '../dom/icons.js';
import { api } from '../core/api.js';
import { full, when } from '../core/format.js';
import { act, actOrThrow, waitOp } from '../core/operations.js';
import { refresh } from '../core/router.js';
import { secretEntryAllowed, secretEntryWhy } from '../core/settings.js';
import { state } from '../core/state.js';
import { accountProblems, isFailing, isLogin, loginDown, needsNoKey, providerOf } from '../components/account-problems.js';
import { usableFor } from '../components/accounts.js';
import { btn as baseBtn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { confirmAction } from '../components/dialog.js';
import { moreMenu } from '../components/menus.js';
import { paintAccountsBadge } from '../components/nav.js';
import { toast } from '../components/notices.js';

/// The one button family, with data-* hooks for the probes (opts.data).
function btn(label, fn, opts = {}) {
  const b = baseBtn(label, fn, opts);
  if (opts.data) Object.assign(b.dataset, opts.data);
  return b;
}

/// Page memory (kept across re-renders, never stored): the view, the Find text, the rows whose details are open, and the
/// sandbox whose key is being changed (with the choice so far).
const UI = { lens: 'provider', q: '', open: new Set(), changing: null, changeTo: null, changeErr: '' };
const NAME = /^[a-z0-9][a-z0-9-]{0,39}$/;

// ── what the host gives, read the way the page needs it ──────────────────────────────────────────────────────────────
/// What its provider answered at the last check ("rejected: HTTP 400 from …" → "HTTP 400 from …").
const refusal = (x) => (x.verification || '').replace(/^rejected:\s*/, '');
/// A key added without its check, or never read: "unverified: …" or a key read on use not read yet.
const checked = (x) => /^verified/.test(x.verification || '');
/// A date as a person reads it on a status line: "2 Nov 2026".
const day = (iso) => new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
/// A sentence that ends: the host's text as it is, with a full stop when it has none.
const sentence = (t) => { const u = t.trim(); const c = u.charAt(0).toUpperCase() + u.slice(1); return /[.!?…]$/.test(c) ? c : c + '.'; };

/// One status per key: [tone, glyph, word, the second line — only when it tells something new (a refusal's code, an
/// expiry, a plan, "read on use · when")].
export function statusOf(x, a) {
  const prov = providerOf(x);
  if (isLogin(x)) {
    if (x.state === 'ok' || x.state === 'expires-soon') return ['ok', 'circle-check', 'Signed in', x.plan ? (x.kind === 'mac' ? 'Claude ' : 'ChatGPT ') + x.plan : null];
    if (x.state === 'expired') return ['warn', 'triangle-alert', 'Expired', null];
    return ['warn', 'triangle-alert', 'Signed out', null];
  }
  if (x.state === 'rejected') return ['fail', 'circle-x', 'Refused', refusal(x).replace(/\s+from\s+\S+$/, '').replace(/^.*?(HTTP \d+).*$/, '$1') || null];
  if (x.state === 'unavailable' || x.state === 'missing' || x.state === 'locked') return ['fail', 'circle-x', 'Can’t read', null];
  if (x.state === 'expired') return ['warn', 'triangle-alert', 'Expired', x.expiresAt ? 'on ' + day(x.expiresAt) : null];
  if (x.state === 'unsupported') return ['off', 'info', 'Not used', 'this build has no ChatGPT sign-in'];
  if (prov === 'custom' || (a.uncheckedProviders || []).includes(prov)) return ['off', 'info', 'No check for this provider', null];
  const exp = x.expiresAt && x.kind === 'setup-token' ? 'expires ' + day(x.expiresAt) + ' (' + when(x.expiresAt) + ')' : null;
  if (checked(x)) return ['ok', 'circle-check', 'Works', x.sourceLabel ? 'read on use' + (x.verifiedAt ? ' · ' + when(x.verifiedAt) : '') : exp];
  return ['off', 'info', 'Not checked', exp];
}
function statusPill(s) { return h('span', { class: 'pill st-' + s[0], 'data-key-status': s[2] }, icon(s[1]), s[2]); }
/// The status as a sandbox row says it: its key's word.
const statusWord = (x, a) => statusOf(x, a)[2].toLowerCase().replace('can’t read', 'can’t be read');

/// Where the key lives, in plain words: [glyph, words, a code part].
export function whereOf(x) {
  if (x.kind === 'mac') return ['user-round', 'This Mac’s Claude login', null];
  if (x.kind === 'codex-mac') return ['user-round', 'This Mac’s Codex login — read, never written', null];
  if (x.sourceLabel) {
    const m = /^([^:]+):\s*(.*)$/.exec(x.sourceLabel);
    const kind = m ? m[1] : x.sourceLabel, ref = m ? m[2] : '';
    return [/1password|aws/i.test(kind) ? 'shield' : 'square-terminal', kind, ref];
  }
  if (x.kind === 'setup-token') return ['key-round', 'Claude subscription token · Keychain', null];
  if (x.kind === 'chatgpt') return ['key-round', 'ChatGPT sign-in · Keychain', null];
  if (x.kind === 'api-key' || x.kind === 'openai-key') return ['key-round', 'API key · Keychain', null];
  return ['key-round', x.hosts && x.hosts.length ? 'Keychain · only to ' + x.hosts.join(', ') : 'Keychain', null];
}
const title = (a, p) => p === 'custom' ? 'Your own services' : (a.sourceTitles || {})[p] || p;
const article = (t) => (/^[AEIOx]/.test(t) ? 'an ' : 'a ');
const isGateway = (a, p) => (a.gatewaySources || []).includes(p) || p === 'openrouter' || p === 'vercel-ai-gateway';
const shownName = (x) => x.kind === 'codex-mac' ? 'This Mac’s Codex login' : x.name;
/// The tools a provider's key serves, by name (the published ones).
function toolsOf(a, p) { return ((a.providerTools || {})[p] || []).map((id) => (a.agentTitles || {})[id] || id); }
function toolsLine(a, p) {
  const t = toolsOf(a, p);
  if (p === 'custom') return 'keys for a service of yours, sent only to the hosts you name';
  if (!t.length) return 'no tool uses it yet';
  return (isGateway(a, p) ? 'many models with one key — ' : '') + 'for ' + t.slice(0, 4).join(', ') + (t.length > 4 ? ' and ' + (t.length - 4) + ' more' : '');
}
/// Another key with the same fingerprint (the same key stored twice).
function twinOf(x, rows) { return x.fingerprint ? rows.find((y) => y !== x && y.fingerprint === x.fingerprint) : null; }
/// "a, b and c" — names in a sentence.
function and(list) { return list.length < 2 ? list.join('') : list.slice(0, -1).join(', ') + ' and ' + list[list.length - 1]; }
/// The names of sandboxes as bold words in a sentence.
function bolds(names) {
  const out = [];
  names.forEach((n, i) => { if (i) out.push(i === names.length - 1 ? ' and ' : ', '); out.push(h('b', null, n)); });
  return out;
}

// ── the page ─────────────────────────────────────────────────────────────────────────────────────────────────────────
export async function viewAccounts() {
  const [a, ov] = await Promise.all([api('accounts'), api('overview').catch(() => state.overview || { sandboxes: [] })]);
  state.accounts = a;
  if (ov && ov.sandboxes) state.overview = state.overview ? { ...state.overview, sandboxes: ov.sandboxes } : ov;
  paintAccountsBadge();
  const rows = a.accounts || [];
  // A key, or a login that is signed in (or one a sandbox relies on); a signed-out Mac login alone is not "a key yet".
  const keys = rows.filter((x) => !isLogin(x) || !loginDown(x) || x.state === 'expired' || (x.usedBy || []).length);
  const all = ov.sandboxes || [];
  const sandboxes = all.filter((s) => s.agent);
  // The title and its one action are the page's title bar (it sticks as the page scrolls); the line under it is not.
  const head = [h('div', { class: 'head ak-head' }, h('h1', null, 'Accounts & keys'),
    keys.length ? btn('Add a key', () => openAddKey(a, null), { primary: true, icon: 'plus' }) : null),
  h('p', { class: 'sub ak-sub' }, 'The keys and sign-ins your sandboxes’ tools use. They stay on this Mac: a sandbox only ever sees a placeholder, and this page never shows a key.')];
  const foot = h('p', { class: 'ak-foot' }, 'Pasting a key here can be turned off in Settings (', h('code', null, 'ui.allow_secret_entry'), '); in a terminal: ',
    h('code', null, 'doz account add'), '.');
  if (!keys.length) return h('div', { class: 'ak-page', 'data-accounts': 'empty' }, head, emptyPage(a), foot);
  const phases = Object.fromEntries(all.map((s) => [s.name, s.phase]));
  const lens = h('span', { class: 'segmented', role: 'group', 'aria-label': 'View' },
    ...[['provider', 'Keys', 'key-round'], ['sandbox', 'Sandboxes', 'box']].map(([v, l, ic]) =>
      h('button', { type: 'button', class: 'seg' + (UI.lens === v ? ' active' : ''), 'aria-pressed': String(UI.lens === v), 'data-ak-lens': v,
        on: { click: () => { UI.lens = v; UI.changing = null; refresh(false); } } }, icon(ic), l)));
  const find = h('input', { type: 'search', placeholder: 'A tool, a key or a sandbox', 'aria-label': 'Find a tool, a key or a sandbox', 'data-ak-find': '' });
  find.value = UI.q;
  const keyCount = rows.filter((x) => !isLogin(x)).length;
  const tools = h('div', { class: 'ak-tools' }, lens, h('label', { class: 'filter-field' }, icon('search'), find),
    h('span', { class: 'ak-count' }, keyCount + (keyCount === 1 ? ' key' : ' keys') + ' · ' + sandboxes.length + (sandboxes.length === 1 ? ' sandbox' : ' sandboxes')));
  const body = h('div', { class: 'ak-body' }, ...(UI.lens === 'provider' ? byProvider(a, rows, phases) : bySandbox(a, rows, sandboxes)));
  const empty = h('p', { class: 'muted ak-nomatch', hidden: true, 'data-ak-nomatch': '' }, 'Nothing matches.');
  const page = h('div', { class: 'ak-page', 'data-accounts': UI.lens }, head, tools, needsYou(a, rows, all), body, empty, foot);
  find.addEventListener('input', () => { UI.q = find.value; applyFind(page); });
  applyFind(page);
  // A re-render (a live change) while typing in Find keeps the focus there.
  if (UI.findFocus) setTimeout(() => { if (find.isConnected) { find.focus(); find.setSelectionRange(find.value.length, find.value.length); } }, 0);
  find.addEventListener('focus', () => { UI.findFocus = true; });
  find.addEventListener('blur', () => { setTimeout(() => { if (document.activeElement !== find) UI.findFocus = false; }, 0); });
  return page;
}

/// Find: hides the rows (and provider groups) that do not mention the text — tool, provider, key or sandbox. In place.
function applyFind(page) {
  const q = UI.q.trim().toLowerCase();
  let shown = 0;
  for (const g of page.querySelectorAll('[data-ak-group]')) {
    const groupHit = !q || g.dataset.akQ.includes(q);
    let any = false;
    for (const r of g.querySelectorAll('[data-ak-q-row]')) {
      const hit = groupHit || r.dataset.akQRow.includes(q);
      r.hidden = !hit;
      if (hit) any = true;
    }
    g.hidden = !(groupHit || any);
    if (!g.hidden) shown++;
  }
  for (const r of page.querySelectorAll('[data-ak-sandbox]')) {
    r.hidden = !!q && !r.dataset.akQRow.includes(q);
    if (!r.hidden) shown++;
  }
  const more = page.querySelector('.ak-more');
  if (more) more.hidden = !!q;
  const none = page.querySelector('[data-ak-nomatch]');
  if (none) none.hidden = !q || shown > 0;
}

// ── 1. Needs you ─────────────────────────────────────────────────────────────────────────────────────────────────────
function needsYou(a, rows, sandboxes) {
  const ps = accountProblems(a, sandboxes);
  if (!ps.length) {
    const times = rows.map((x) => x.verifiedAt).filter(Boolean).sort();
    const unchecked = rows.filter((x) => !isLogin(x) && statusOf(x, a)[2] === 'Not checked').length;
    return h('div', { class: 'ak-ok', role: 'status', 'data-ak-allgood': '' }, icon('circle-check'), h('span', null, 'Every key works'),
      h('span', { class: 'muted' }, (times.length ? '· checked ' + when(times[times.length - 1]) : '')
        + (unchecked ? (times.length ? ' · ' : '· ') + unchecked + ' not checked yet' : '')));
  }
  const hit = new Set(ps.flatMap((p) => p.affected));
  const nKeys = ps.reduce((n, p) => n + 1 + p.twins.length, 0);
  return h('section', { class: 'ak-needs', 'aria-label': 'Needs you', 'data-ak-needs': '' },
    h('div', { class: 'ak-needs-h' }, icon('triangle-alert'), h('span', null, 'Needs you'),
      h('span', { class: 'muted' }, '— ' + nKeys + (nKeys === 1 ? ' key' : ' keys') + (hit.size ? ', ' + hit.size + (hit.size === 1 ? ' sandbox' : ' sandboxes') + ' affected' : ', no sandbox affected'))),
    ...ps.map((p) => needLine(a, rows, p)));
}

function needLine(a, rows, p) {
  const x = p.row, prov = providerOf(x), t = title(a, prov);
  const used = p.affected;
  const tw = p.twins.map((y) => y.name);
  const breaks = used.length ? [...bolds(used), (used.length === 1 ? ' gets no ' : ' get no ') + t + ' key at ' + (used.length === 1 ? 'its' : 'their') + ' next session.'] : ['No sandbox uses it.'];
  const twinLine = tw.length ? [' ', ...bolds(tw), (tw.length === 1 ? ' is the same key and is' : ' are the same key and are') + ' failing too.'] : [];
  let ttl, glyph = 'circle-x', d, fix = null, fixRemoves = false;
  const more = [];
  if (isLogin(x)) {
    const cmd = x.kind === 'mac' ? 'claude' : 'codex login';
    glyph = 'user-round';
    ttl = (x.kind === 'mac' ? 'This Mac’s Claude login' : 'This Mac’s Codex login') + (x.state === 'expired' ? ' has expired' : ' is signed out');
    const other = rows.find((y) => providerOf(y) === prov && !isLogin(y) && !isFailing(y) && y.kind !== 'chatgpt' && statusOf(y, a)[0] !== 'warn');
    d = [x.isDefault ? 'It is ' + t + '’s default: ' : '', ...breaks, ' Sign in with ', h('code', null, cmd), ' on this Mac'
      + (x.kind === 'mac' ? ' (then ' : ''), x.kind === 'mac' ? h('code', null, '/login') : null, x.kind === 'mac' ? ')' : '',
      x.isDefault && other ? ', or make another key the default.' : '.'];
    fix = copyBtn(cmd, 'Copy ' + cmd, { small: true, icon: 'copy', data: { akFix: 'copy' } });
    if (x.isDefault && other) {
      more.push(btn('Use ' + other.name + ' instead', () => act({ action: 'account-default', account: other.name }),
        { small: true, quiet: true, title: 'Make ' + other.name + ' ' + t + '’s default' }));
    }
  } else if (x.state === 'rejected') {
    ttl = x.name + ' was refused by ' + t + (statusOf(x, a)[3] ? ' (' + statusOf(x, a)[3] + ')' : '');
    d = [...breaks, ' Wrong, revoked or out of credit.', ...twinLine, used.length ? ' Replace it with a new key under the same name.' : ''];
    // Used by no sandbox: Remove is the likelier fix (Replace stays in ⋯).
    fix = used.length ? btn('Replace…', () => openAddKey(a, prov, null, { replace: x.name }), { small: true, icon: 'key-round' })
      : removeBtn(x, { small: true, quiet: true });
    fixRemoves = !used.length;
  } else if (x.state === 'unavailable') {
    ttl = x.name + ' can’t be read — ' + (x.sourceLabel ? 'its source did not answer' : 'it did not answer');
    d = [...breaks, ' ', x.sourceProblem ? sentence(x.sourceProblem) : 'Fix it where the key lives, then Read again.', ...twinLine];
    fix = btn('Read again', () => act({ action: 'account-refresh', account: x.name }), { small: true, quiet: !used.length, icon: 'refresh-cw' });
  } else if (x.state === 'locked') {
    ttl = x.name + ' can’t be read — the login keychain is locked';
    d = [...breaks, ' Unlock the login keychain (Keychain Access), then Check again.', ...twinLine];
    fix = btn('Check again', () => act({ action: 'account-verify', account: x.name }), { small: true, quiet: !used.length, icon: 'badge-check' });
  } else {
    ttl = x.name + ' can’t be read — its keychain item is gone';
    d = [...breaks, ...twinLine, ' Add it again under the same name' + (tw.length ? '; then remove ' + and(tw) + '.' : '.')];
    fix = btn('Add it again…', () => openAddKey(a, prov, null, { replace: x.name }), { small: true, quiet: !used.length, icon: 'key-round' });
  }
  const items = isLogin(x) ? [] : [
    x.sourceLabel && x.state !== 'unavailable' ? { label: 'Read again', icon: 'refresh-cw', desc: 'Read it from where you keep it now', onSelect: () => act({ action: 'account-refresh', account: x.name }) } : null,
    x.state !== 'locked' && !x.sourceLabel ? { label: 'Check again', icon: 'badge-check', desc: 'One tiny request to ' + t + ' with it', onSelect: () => act({ action: 'account-verify', account: x.name }) } : null,
    x.state === 'rejected' && !used.length ? { label: 'Replace…', icon: 'key-round', desc: 'A new key under the same name', onSelect: () => openAddKey(a, prov, null, { replace: x.name }) } : null,
    ...[x, ...p.twins].filter((y) => !(fixRemoves && y === x)).map((y) => removeItem(y)),
  ].filter(Boolean);
  return h('div', { class: 'ak-need ' + (used.length ? p.tone : 'quiet'), 'data-ak-failing': x.name, 'data-ak-need': [x, ...p.twins].map((y) => y.name).join(' '),
    'data-ak-affects': used.join(' ') },
    icon(glyph), h('div', { class: 't' }, ttl), h('div', { class: 'd' }, ...d.filter((v) => v !== null && v !== '')),
    h('div', { class: 'acts' }, fix, ...more, items.length ? moreMenu('More for ' + x.name, items, { small: true }).el : null));
}

function removeItem(x) {
  if (isLogin(x)) return null;
  return { label: 'Remove ' + x.name + '…', icon: 'trash-2', danger: true,
    desc: x.sourceLabel ? 'Only Dozable’s record — where you keep the key is not touched' : 'Its keychain item is deleted',
    onSelect: () => confirmRemove(x) };
}
function removeBtn(x, opts) { return btn('Remove…', () => confirmRemove(x), { ...opts, icon: 'trash-2' }); }
function confirmRemove(x) {
  return confirmAction('Remove account ' + x.name,
    (x.sourceLabel ? 'Only Dozable’s record goes' : 'Its keychain item is deleted') + ((x.usedBy || []).length ? '; sandboxes that use it (' + x.usedBy.join(', ') + ') must move to another key first' : '') + '.',
    x.name, { action: 'account-rm', account: x.name });
}
function copyBtn(text, label, opts) {
  return btn(label, async (ev) => {
    const b = ev.currentTarget;
    try { await navigator.clipboard.writeText(text); toast('Copied: ' + text); } catch (_) { b.title = 'Copy it yourself: ' + text; toast('Type ' + text + ' in Terminal on this Mac'); }
  }, opts);
}

// ── 3. the Keys view ─────────────────────────────────────────────────────────────────────────────────────────────────
function byProvider(a, rows, phases) {
  const order = [...(a.providers || []), 'custom'];
  // The Codex login is listed only while signed in (or relied on); a signed-out Claude login only while it is the default
  // or a sandbox relies on it.
  const listed = (x) => !(x.kind === 'codex-mac' && x.state !== 'ok' && !(x.usedBy || []).length);
  const have = order.filter((p) => rows.some((x) => providerOf(x) === p && listed(x) && (!isLogin(x) || !loginDown(x) || x.isDefault || (x.usedBy || []).length)));
  const out = have.map((p) => providerGroup(a, rows.filter((x) => providerOf(x) === p && listed(x)), p, rows, phases));
  const without = order.filter((p) => !have.includes(p));
  if (without.length) {
    out.push(h('div', { class: 'ak-more' }, h('span', null, 'No key yet:'),
      ...without.map((p) => btn(p === 'custom' ? 'Your own service' : title(a, p), () => openAddKey(a, p), { small: true, quiet: true, icon: 'plus' }))));
  }
  return out;
}

function providerGroup(a, keys, p, rows, phases) {
  const custom = p === 'custom';
  const t = title(a, p);
  const q = [p, t, ...toolsOf(a, p)].join(' ').toLowerCase();
  const hasDef = !custom && keys.some((x) => x.isDefault);
  const tbody = h('tbody');
  for (const x of keys) {
    tbody.append(keyRow(a, rows, x, p, phases));
    if (UI.open.has(x.name + '|' + x.kind)) tbody.append(detailsRow(x));
  }
  if (p === 'anthropic') {
    const items = hasDef ? [{ label: 'Set default', icon: 'check', desc: 'No default: a sandbox that follows it gets no Anthropic key',
      onSelect: () => act({ action: 'account-default', account: 'none' }) }] : [];
    tbody.append(h('tr', { class: 'none-row', 'data-ak-q-row': 'no default' },
      h('td', { colspan: '3' }, 'No default — a Claude Code or pi sandbox that follows the default gets no Anthropic key'),
      h('td', { class: 'c-def' }, defTick(!hasDef, 'No default for Anthropic')),
      h('td', { class: 'c-acts' }, h('div', { class: 'ak-acts' }, items.length ? moreMenu('More for no default', items, { small: true }).el : null))));
  } else if (!custom && !hasDef) {
    tbody.append(h('tr', { class: 'none-row', 'data-ak-q-row': '' },
      h('td', { colspan: '5' }, h('span', { class: 'ak-none' }, icon('info'),
        p === 'openai' ? 'No default yet — a Codex sandbox that follows the default gets no key until you choose one: ⋯ › Set default.' : 'No default yet — choose one above: ⋯ › Set default.'))));
  }
  const table = h('table', { class: 'ak-t' },
    h('colgroup', null, h('col', { class: 'c-key' }), h('col', { class: 'c-st' }), h('col', { class: 'c-used' }), h('col', { class: 'c-def' }), h('col', { class: 'c-acts' })),
    h('thead', null, h('tr', null, h('th', null, 'Key'), h('th', null, 'Status'), h('th', null, 'Used by'), h('th', { class: 'c-def' }, custom ? '' : 'Default'),
      h('th', null, h('span', { class: 'sr-only' }, 'Actions')))),
    tbody);
  const mac = keys.find((x) => x.kind === 'mac');
  const keep = p === 'anthropic' && mac && (a.keepalive || ['ok', 'expires-soon', 'expired'].includes(mac.state)) ? keepAlive(a) : null;
  return h('section', { class: 'ak-group', 'data-provider': p, 'data-ak-group': p, 'data-ak-q': q },
    h('div', { class: 'ak-gh' },
      h('span', { class: 'ak-av', 'aria-hidden': 'true' }, custom ? '+' : t.charAt(0)),
      h('h2', null, t, isGateway(a, p) ? h('span', { class: 'tag outline' }, 'gateway') : null),
      h('span', { class: 'for' }, toolsLine(a, p)),
      btn(custom ? 'Add a custom key…' : 'Add ' + t + ' key', () => openAddKey(a, p), { small: true, quiet: true, icon: 'plus' })),
    h('div', { class: 'panel' }, table), keep);
}

function keyRow(a, rows, x, p, phases) {
  const s = statusOf(x, a);
  const [glyph, words, ref] = whereOf(x);
  const twin = twinOf(x, rows);
  const custom = p === 'custom';
  const def = custom ? null : defTick(!!x.isDefault, title(a, p) + '’s default: ' + shownName(x));
  const used = x.usedBy || [];
  const verb = nextVerb(a, x, p);
  const open = UI.open.has(x.name + '|' + x.kind);
  const items = [
    !custom && x.kind !== 'codex-mac' && !x.isDefault
      ? { label: 'Set default', icon: 'check', desc: 'Sandboxes that follow ' + title(a, p) + '’s default use it', onSelect: () => act({ action: 'account-default', account: x.name }) } : null,
    !isLogin(x) && !isFailing(x) && !(p === 'custom' || (a.uncheckedProviders || []).includes(p)) && !x.sourceLabel && checked(x)
      ? { label: 'Check again', icon: 'badge-check', desc: 'One tiny request to ' + title(a, p) + ' with it', onSelect: () => act({ action: 'account-verify', account: x.name }) } : null,
    x.sourceLabel && x.state !== 'unavailable' ? { label: 'Read again', icon: 'refresh-cw', desc: 'Read it from where you keep it now', onSelect: () => act({ action: 'account-refresh', account: x.name }) } : null,
    editable(x) ? { label: 'Edit…', icon: 'settings', desc: editDesc(x), onSelect: () => openEditKey(a, x) } : null,
    { label: open ? 'Hide details' : 'Details', icon: 'info', desc: 'Fingerprint, keychain item, source, expiry',
      onSelect: () => { open ? UI.open.delete(x.name + '|' + x.kind) : UI.open.add(x.name + '|' + x.kind); refresh(false); } },
    isLogin(x) ? null : removeItem(x),
  ].filter(Boolean);
  const q = [x.name, x.kind, words, ref || '', ...used].join(' ').toLowerCase();
  return h('tr', { class: isFailing(x) || (isLogin(x) && loginDown(x) && used.length) ? 'failing' : null, 'data-ak-key': x.name, 'data-ak-kind': x.kind, 'data-ak-q-row': q },
    h('td', { class: 'c-key' },
      h('div', { class: 'ak-name' }, shownName(x), twin ? h('span', { class: 'tag warn', 'data-ak-twin': twin.name, title: 'The same fingerprint: one key stored twice' }, 'same key as ' + twin.name) : null),
      h('div', { class: 'ak-where' }, icon(glyph), h('span', ref ? { class: 'ak-where-k' } : null, words), ref ? h('code', { title: ref }, ref) : null)),
    h('td', { class: 'c-st' }, h('div', { class: 'ak-state' }, statusPill(s), s[3] ? h('span', { class: 'muted' }, s[3]) : null)),
    h('td', { class: 'c-used' }, used.length
      ? oneLineChips(used.map((n) => h('a', { class: 'ak-chip', href: '#/sandbox/' + n, title: 'Open ' + n, 'data-name': n }, h('span', { class: 'ph-dot ph-' + (phases[n] || 'off') + phaseMark(phases[n] || 'off'), 'aria-hidden': 'true' }), n)))
      : h('div', { class: 'ak-used' }, h('span', { class: 'none' }, 'no sandbox'))),
    h('td', { class: 'c-def' }, def),
    h('td', { class: 'c-acts' }, h('div', { class: 'ak-acts' }, verb, moreMenu('More for ' + shownName(x), items, { small: true }).el)));
}

/// The default column: a tick on the provider's default, nothing on the others (Set default is in the row's ⋯ menu).
function defTick(on, label) {
  return on ? h('span', { class: 'ak-def', role: 'img', 'aria-label': label, title: 'The default — sandboxes that follow it use this', 'data-ak-default': '' }, icon('check')) : null;
}

/// Sandbox chips on ONE line: as many as fit, then "… +N" naming the rest (a key many sandboxes use never grows the row).
function oneLineChips(chips) {
  const more = h('span', { class: 'ak-chip more', 'data-ak-more': '' });
  const box = h('div', { class: 'ak-used one-line' }, ...chips, more);
  let width = -1;
  const fit = () => {
    if (box.clientWidth === width) return;
    width = box.clientWidth;
    for (const c of chips) c.hidden = false;
    more.hidden = true;
    if (!width || box.scrollWidth <= width) return;
    more.hidden = false;
    let n = chips.length;
    do { chips[--n].hidden = true; more.textContent = '… +' + (chips.length - n); } while (n > 1 && box.scrollWidth > width);
    more.title = chips.slice(n).map((c) => c.dataset.name).join(', ');
  };
  new ResizeObserver(fit).observe(box);
  return box;
}

function detailsRow(x) {
  const d = h('dl', { class: 'ak-details', 'data-ak-details': x.name });
  const add = (k, v) => { if (v) d.append(h('dt', null, k), h('dd', null, v)); };
  add('Fingerprint', x.fingerprint ? x.fingerprint + ' (a sha256 prefix — never the key)' : null);
  add('Keychain item', x.keychainService);
  add('Source', x.sourceLabel);
  add('Identity', x.identity);
  add('Expires', x.expiresAt ? full(x.expiresAt) + ' (' + when(x.expiresAt) + ')' : null);
  add('Only to', x.hosts && x.hosts.length ? x.hosts.join(', ') : null);
  add('Last check', x.verification);
  add('Kind', x.kind);
  add('Remove', isLogin(x) ? 'not removable — it is this Mac’s own login' : x.sourceLabel ? 'only Dozable’s record — the source is not touched' : 'deletes its keychain item');
  return h('tr', { class: 'details-row', 'data-ak-q-row': x.name.toLowerCase() }, h('td', { colspan: '5' }, d));
}

/// The one verb that helps now: Replace… (refused), Add again… (its keychain item is gone), Read again (a key read on use
/// that did not answer), Check again (locked), Check (never checked).
function nextVerb(a, x, p) {
  if (isLogin(x)) return null;
  if (x.state === 'rejected') return btn('Replace…', () => openAddKey(a, p, null, { replace: x.name }), { small: true, icon: 'key-round', title: 'A new key under the same name — sandboxes that use it keep using it' });
  if (x.state === 'missing') return btn('Add again…', () => openAddKey(a, p, null, { replace: x.name }), { small: true, icon: 'key-round', title: 'Paste the key again under the same name' });
  if (x.state === 'unavailable') return btn('Read again', () => act({ action: 'account-refresh', account: x.name }), { small: true, icon: 'refresh-cw', title: 'Read the key from where you keep it again now' });
  if (x.state === 'locked') return btn('Check again', () => act({ action: 'account-verify', account: x.name }), { small: true, quiet: true, icon: 'badge-check', title: 'After unlocking the login keychain' });
  if (statusOf(x, a)[2] === 'Not checked' && !x.sourceLabel) return btn('Check', () => act({ action: 'account-verify', account: x.name }), { small: true, quiet: true, icon: 'badge-check', title: 'One tiny request to ' + title(a, p) + ' with it' });
  return null;
}

function keepAlive(a) {
  const sw = h('input', { type: 'checkbox', role: 'switch', 'aria-label': 'Keep this Mac’s Claude login fresh while a sandbox uses it', 'data-ak-keepalive': '' });
  sw.checked = !!a.keepalive;
  sw.addEventListener('change', () => act({ action: 'account-keepalive', enabled: sw.checked }));
  return h('label', { class: 'ak-keep' }, icon('refresh-cw'), h('div', null, h('b', null, 'Keep this Mac’s Claude login fresh while a sandbox uses it'),
    h('div', { class: 'muted' }, 'Shortly before it expires, Dozable runs Claude Code on this Mac once, so the login renews. Off: it renews when you next use claude here.')), sw);
}

// ── 2. the Sandboxes view ────────────────────────────────────────────────────────────────────────────────────────────
/// Every sandbox running a tool: the key it uses now and how it got it; Change in place (account-use, from its next session).
function bySandbox(a, rows, sandboxes) {
  if (!sandboxes.length) return [h('p', { class: 'muted' }, 'No sandbox runs a tool yet.')];
  const trs = sandboxes.map((s) => sandboxRow(a, rows, s));
  return [h('p', { class: 'muted ak-lead' }, 'The key each sandbox’s tool uses now. A change applies from its next session; the sandbox only ever sees a placeholder.'),
    h('div', { class: 'panel' }, h('table', { class: 'ak-s' },
      h('colgroup', null, h('col', { class: 'c-sbx' }), h('col', { class: 'c-tool' }), h('col', { class: 'c-key' }), h('col', { class: 'c-how' }), h('col', { class: 'c-st' }), h('col', { class: 'c-acts' })),
      h('thead', null, h('tr', null, ...['Sandbox', 'Tool', 'Key', 'How it gets it', 'Status'].map((t) => h('th', null, t)), h('th', null, h('span', { class: 'sr-only' }, 'Actions')))),
      h('tbody', null, ...trs)))];
}

function sandboxRow(a, rows, s) {
  const k = rows.find((x) => (x.usedBy || []).includes(s.name));
  const p = k ? providerOf(k) : null;
  const tool = (a.agentTitles || {})[s.agent] || (a.toolTitles || {})[s.agent] || s.agent;
  // The overview names the key a sandbox RESOLVES to, not its choice: one that is its provider's default is followed.
  const chosen = !!k && !k.isDefault;
  const q = [s.name, tool, s.agent, k ? k.name : '', p ? title(a, p) : ''].join(' ').toLowerCase();
  const link = h('a', { class: 'name', href: '#/sandbox/' + s.name }, s.name);
  // A sandbox whose network reaches no model provider needs no key — never a warning.
  if (needsNoKey(s) || (!k && !s.accountApplies)) {
    return h('tr', { 'data-ak-sandbox': s.name, 'data-ak-notneeded': '', 'data-ak-q-row': q },
      h('td', { class: 'c-sbx' }, link), h('td', { class: 'c-tool' }, tool), h('td', { class: 'c-key' }, h('span', { class: 'muted' }, '—')),
      h('td', { class: 'c-how how' }, 'needs none: its network reaches no model provider'),
      h('td', { class: 'c-st' }, h('span', { class: 'state-word', 'data-key-status': 'Not needed' }, 'Not needed')), h('td', { class: 'c-acts' }));
  }
  const st = k ? statusOf(k, a) : null;
  const bad = !k || (st && st[0] !== 'ok' && st[0] !== 'off');
  if (UI.changing === s.name) return changeRow(a, rows, s, link, tool, q);
  const how = chosen ? 'chosen for this sandbox' : k ? 'follows ' + title(a, p) + '’s default' : s.account === 'none' ? 'none chosen' : 'follows the default — there is none';
  return h('tr', { 'data-ak-sandbox': s.name, 'data-ak-q-row': q },
    h('td', { class: 'c-sbx' }, link), h('td', { class: 'c-tool' }, tool),
    h('td', { class: 'c-key' }, k ? shownName(k) : h('span', { class: 'muted' }, 'none')),
    h('td', { class: 'c-how how' }, how),
    h('td', { class: 'c-st' }, st ? statusPill(st) : statusPill(['warn', 'triangle-alert', 'No key', null])),
    h('td', { class: 'c-acts' }, h('div', { class: 'ak-acts' }, btn('Change…', () => { UI.changing = s.name; UI.changeTo = null; UI.changeErr = ''; refresh(false); },
      { small: true, quiet: !bad, icon: 'key-round', title: 'Which key ' + s.name + ' uses — from its next session', data: { akChange: s.name } }))));
}

/// Change in place: a select of the keys its tool accepts, its provider's default, No key; Use it = account-use.
function changeRow(a, rows, s, link, tool, q) {
  const u = usableFor(a, s.agent);
  const label = (x) => shownName(x) + ' — ' + statusWord(x, a);
  const opts = [];
  for (const x of u.usable) opts.push([x.name, label(x)]);
  const defProv = u.def ? title(a, providerOf(u.def)) : u.srcs ? title(a, u.srcs[0]) : u.kinds && u.kinds.includes('openai-key') ? 'OpenAI' : 'Anthropic';
  opts.push(['default', 'Follow ' + defProv + '’s default' + (u.def ? ' (' + shownName(u.def) + ' — ' + statusWord(u.def, a) + ')' : u.defName === 'none' ? ' (there is none)' : '')]);
  opts.push(['none', 'No key']);
  const sel = h('select', { 'aria-label': 'Key for ' + s.name, 'data-ak-change-select': s.name }, ...opts.map(([v, l]) => h('option', { value: v }, l)));
  const k = rows.find((x) => (x.usedBy || []).includes(s.name));
  const current = !k || k.isDefault ? 'default' : k.name;
  sel.value = UI.changeTo ?? (opts.some(([v]) => v === current) ? current : opts[0][0]);
  sel.addEventListener('change', () => { UI.changeTo = sel.value; });
  const asleep = s.phase && s.phase !== 'running' && s.phase !== 'off' ? ' — it is ' + (s.phaseLabel || s.phase).toLowerCase() + ' now' : '';
  const use = btn('Use it', async (ev) => {
    const b = ev.currentTarget;
    b.disabled = true;
    UI.changeErr = '';
    try {
      await actOrThrow({ action: 'account-use', sandbox: s.name, account: sel.value });
      UI.changing = null; UI.changeTo = null;
      toast(s.name + ': ' + (sel.value === 'default' ? 'follows ' + defProv + '’s default' : sel.value === 'none' ? 'no key' : sel.value) + ' from its next session');
      refresh(false);
    } catch (e) {
      UI.changeErr = e.message || String(e);
      b.disabled = false;
      err.textContent = UI.changeErr;
    }
  }, { small: true, primary: true, icon: 'check', data: { akUse: s.name } });
  const err = h('div', { class: 'dlg-error', role: 'alert' }, UI.changeErr);
  return h('tr', { class: 'changing', 'data-ak-sandbox': s.name, 'data-ak-q-row': q },
    h('td', { class: 'c-sbx' }, link), h('td', { class: 'c-tool' }, tool),
    h('td', { class: 'c-key c-change', colspan: '3' }, h('div', { class: 'ak-change' }, sel,
      h('span', { class: 'muted' }, 'from its next session' + asleep)), err),
    h('td', { class: 'c-acts' }, h('div', { class: 'ak-acts' }, use,
      btn('Cancel', () => { UI.changing = null; UI.changeTo = null; refresh(false); }, { small: true, quiet: true, iconOnly: true, icon: 'x' }))));
}

function emptyPage(a) {
  return h('div', { class: 'ak-empty', 'data-ak-empty': '' },
    h('h2', null, 'No keys yet'),
    h('p', { class: 'muted' }, 'A sandbox’s tool needs a key or a sign-in to reach its model. Dozable keeps it on this Mac and gives the sandbox only a placeholder.'),
    h('div', { class: 'ak-cards' },
      h('div', { class: 'ak-card' }, h('b', null, icon('user-round'), 'Use this Mac’s Claude login'),
        h('span', { class: 'muted' }, 'For Claude Code. Sign in with claude on this Mac and it shows up here by itself.'), h('code', null, 'claude   (then /login)')),
      h('div', { class: 'ak-card' }, h('b', null, icon('key-round'), 'Paste an API key'),
        h('span', { class: 'muted' }, (a.providers || []).map((p) => title(a, p)).join(', ') + '.'),
        h('div', null, btn('Add a key', () => openAddKey(a, null), { primary: true, icon: 'plus' }))),
      h('div', { class: 'ak-card' }, h('b', null, icon('shield'), 'Keep it in 1Password or AWS'),
        h('span', { class: 'muted' }, 'Dozable reads it when a sandbox needs it and keeps it in memory only.'),
        h('div', null, btn('Show me how', () => openAddKey(a, null, '1password'), { small: true, icon: 'info' })))),
    h('p', { class: 'muted ak-empty-foot' }, 'Setting up a particular tool? Quick try asks for exactly the key it needs.'));
}

// ── 4. Add a key: for what → the key → the check ─────────────────────────────────────────────────────────────────────
let FLOW = null;

/// pid: a provider (null: ask for what); source: where the key comes from first (paste by default);
/// opts.replace: the name of a failing key this one replaces in place.
export function openAddKey(a, pid, source, opts = {}) {
  if (FLOW && FLOW.d && FLOW.d.open) FLOW.d.close();
  const d = h('dialog', { class: 'dlg ak-flow', 'aria-labelledby': 'ak-flow-title', 'data-ak-flow': '' });
  d.addEventListener('close', () => { d.remove(); if (FLOW && FLOW.d === d) FLOW = null; });
  document.body.append(d);
  const old = opts.replace ? (a.accounts || []).find((x) => x.name === opts.replace && !isLogin(x)) : null;
  FLOW = { d, a, step: pid ? 2 : 1, provider: pid, source: source || (pid === 'custom' ? 'custom' : 'paste'),
    kind: old && (old.kind === 'setup-token' || old.kind === 'api-key') ? old.kind : 'api-key', plan: (old && old.plan) || 'max', q: '', name: old ? old.name : '',
    ref: '', host: 'api.example.com', envVar: 'EXAMPLE_API_KEY', header: 'bearer', makeDefault: null, result: null, busy: false, old };
  d.showModal();
  paintFlow();
}

// ── Edit a key: its name, a setup token's plan, a new value under the same name — ONE step ─────────────────────────────
/// Every key but a login (this Mac's own, never renamed) and a ChatGPT sign-in (signed in again under a new name).
const editable = (x) => !isLogin(x) && x.kind !== 'chatgpt';
/// A key Dozable keeps in the keychain itself — its value may be replaced here (never one read from 1Password, AWS or a
/// command, a custom key or a keychain item the person named).
const valueHere = (x) => !x.sourceLabel && !x.adopted && providerOf(x) !== 'custom' && ['api-key', 'openai-key', 'key', 'setup-token'].includes(x.kind);
function editDesc(x) {
  return 'Its name' + (x.kind === 'setup-token' ? ', its plan' : '') + (valueHere(x) ? ' or a new key under the same name' : '');
}
/// `doz account add NAME … --force` for this key — what changes its value (or its source) in Terminal.
function replaceCommand(x, name) {
  const n = name || x.name;
  if (providerOf(x) === 'custom') {
    return 'doz account add ' + n + ' --custom' + (x.hosts || ['HOST']).map((hh) => ' --host ' + shq(hh)).join('') + ' --env-var VAR --bearer --force';
  }
  const flag = x.kind === 'setup-token' ? ' --setup-token --plan ' + (x.plan || 'max') : provFlag(providerOf(x));
  if (x.sourceLabel) {
    const m = /^([^:]+):\s*(.*)$/.exec(x.sourceLabel);
    const kind = m ? m[1].toLowerCase() : '', ref = m ? m[2] : '';
    const from = kind.startsWith('1password') ? ' --from ' + shq(ref || 'op://VAULT/ITEM/FIELD')
      : kind.startsWith('aws') ? ' --from ' + shq('aws:' + (ref || 'ARN')) : ' --from-command ' + shq(ref || 'PROGRAM');
    return 'doz account add ' + n + flag + from + ' --force';
  }
  return 'doz account add ' + n + flag + ' --force';
}

/// The Edit… dialog: Name, a setup token's Plan, Replace the key (optional). Save applies only what changed — the name
/// and plan in one `account-edit` action, then a new value through POST /api/v1/accounts with replace + edit — and says
/// the outcome here (a new value's check, like Add's last step).
export function openEditKey(a, x) {
  if (FLOW && FLOW.d && FLOW.d.open) FLOW.d.close();
  const d = h('dialog', { class: 'dlg ak-flow ak-edit', 'aria-labelledby': 'ak-edit-title', 'data-ak-edit': x.name });
  d.addEventListener('close', () => { d.remove(); if (FLOW && FLOW.d === d) FLOW = null; });
  document.body.append(d);
  FLOW = { d, edit: true };
  const p = providerOf(x);
  const st = { name: x.name, plan: x.plan || 'max', busy: false, error: '', result: null };
  d.showModal();

  const paint = () => {
    const close = btn('Close', () => d.close(), { small: true, quiet: true, iconOnly: true, icon: 'x' });
    const head = h('div', { class: 'dlg-head ak-flow-head' }, h('h2', { class: 'h-title', id: 'ak-edit-title' }, 'Edit ' + st.name), close);
    const body = h('div', { class: 'dlg-body ak-flow-body' });
    const foot = h('div', { class: 'dlg-foot dlg-buttons' });
    if (st.result) {
      const r = st.result;
      const rows = [];
      for (const line of r.lines) rows.push(h('div', null, icon('check'), ' ', line));
      if (r.row) {
        const s = statusOf(r.row, r.a || a);
        const users = r.row.usedBy || [];
        rows.push(h('div', { class: 'ak-result', role: 'status', 'data-ak-result': 'done' }, statusPill(s),
          h('div', null, h('b', null, 'The new key ' + (s[0] === 'fail' ? 'is saved, but ' + s[2].toLowerCase() + '.' : s[2] === 'Works' ? 'works.' : 'is saved.')),
            h('div', { class: 'muted' }, (s[2] === 'Works' ? title(a, p) + ' accepted it; it is in your login keychain.' : 'It is in your login keychain' + (s[3] ? ' — ' + s[3] : '') + '.')
              + (users.length ? ' ' + and(users) + (users.length === 1 ? ' uses' : ' use') + ' it from ' + (users.length === 1 ? 'its' : 'their') + ' next session.' : '')))));
      }
      body.append(h('div', { class: 'ak-edit-done', 'data-ak-edit-done': '' }, ...rows));
      foot.append(h('span', { class: 'spacer' }), btn('Done', () => d.close(), { primary: true, icon: 'check' }));
      d.replaceChildren(head, body, foot);
      return;
    }
    const name = h('input', { class: 'ak-in', autocomplete: 'off', spellcheck: 'false', 'aria-label': 'Name', 'data-ak-edit-name': '' });
    name.value = st.name === x.name ? (st.newName ?? x.name) : st.name;
    name.addEventListener('input', () => { st.newName = name.value.trim(); paintCmd(); });
    const used = x.usedBy || [];
    body.append(h('div', { class: 'ak-two' },
      h('div', { class: 'field' }, h('span', null, 'Provider'), h('div', null, h('b', null, p === 'custom' ? 'Your own service' : title(a, p)))),
      h('label', { class: 'field' }, h('span', null, 'Name'), name,
        h('small', null, 'a-z 0-9 -. ' + (used.length ? and(used) + (used.length === 1 ? ' uses' : ' use') + ' it and keeps it under the new name.' : 'No sandbox uses it.')))));
    let plan = null;
    if (x.kind === 'setup-token') {
      plan = h('select', { class: 'ak-in', 'aria-label': 'Plan', 'data-ak-edit-plan': '' }, ...['max', 'pro', 'team', 'enterprise'].map((v) => h('option', { value: v }, v)));
      plan.value = st.plan;
      plan.addEventListener('change', () => { st.plan = plan.value; paintCmd(); });
      body.append(h('label', { class: 'field' }, h('span', null, 'Plan'), plan,
        h('small', null, 'Claude Code shows it and picks its default model by it — sessions started from now on get it.')));
    }
    const cmdBox = h('div', { class: 'ak-cmdbox' });
    let cmdLine = null;
    const paintCmd = () => {
      if (!cmdLine) return;
      const line = cmdLine();
      cmdBox.replaceChildren(h('pre', { class: 'ak-cmd', 'data-ak-cmd': '' }, line), h('div', null, copyBtn(line, 'Copy', { small: true, icon: 'copy' })));
    };
    let secret = null;
    const here = valueHere(x);
    if (here && secretEntryAllowed()) {
      const what = x.kind === 'setup-token' ? 'setup token' : 'key';
      secret = h('input', { class: 'ak-in', type: 'password', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', 'data-secret': '1',
        placeholder: 'leave empty to keep the current ' + what, 'aria-label': 'Replace the ' + what, 'data-ak-edit-secret': '' });
      body.append(h('label', { class: 'field' }, h('span', null, 'Replace the ' + what), secret,
        h('small', null, 'Optional. Not shown, not kept in this page. ' + ((a.uncheckedProviders || []).includes(p) ? title(a, p) + ' has no key check, so it is saved as it is'
          : 'Checked with one tiny request to ' + title(a, p)) + ', then kept in your login keychain under the same name'
          + (used.length ? '; ' + (used.length === 1 ? 'its sandbox gets' : 'its sandboxes get') + ' it at the next session.' : '.'))));
    } else if (here) {
      cmdLine = () => replaceCommand(x, (st.newName || '').trim() && NAME.test(st.newName.trim()) ? st.newName.trim() : st.name).replace(/--plan \S+/, '--plan ' + st.plan);
      body.append(callout('info', { attrs: { 'data-secret-why': '1' }, title: 'To replace the key',
        body: [h('p', null, secretEntryWhy() + ' — in Terminal on this Mac (it asks for the key and does not echo it; the name, default and sandboxes are kept):'), cmdBox] }));
    } else {
      cmdLine = () => replaceCommand(x, st.name);
      const why = x.sourceLabel ? 'Its key is read from ' + x.sourceLabel.replace(/:.*$/, '') + ' each time a sandbox needs it. Where it is read from is changed in Terminal:'
        : providerOf(x) === 'custom' ? 'A custom key names the hosts it may go to, so its key and hosts are changed in Terminal:'
        : 'Its key is a keychain item you named, so Dozable does not change it. To keep a new key under this name instead, in Terminal:';
      body.append(h('div', { class: 'field' }, h('span', null, 'The key'), h('p', { class: 'muted' }, why), cmdBox));
    }
    paintCmd();
    const err = h('div', { class: 'dlg-error', role: 'alert', 'data-ak-error': '' }, st.error || '');
    body.append(err);
    const fail = (t) => { st.error = t; err.textContent = t; };
    const save = btn(st.busy ? 'Saving…' : 'Save', async (ev) => {
      const b = ev.currentTarget;
      const value = secret ? secret.value : '';
      if (secret) secret.value = '';                              // gone from the page before any request
      const n = name.value.trim();
      const taken = (a.accounts || []).some((y) => y.name === n && y !== x);
      if (!NAME.test(n) || ['default', 'none', 'mac'].includes(n)) return fail('The name: 1–40 of a-z 0-9 - (not mac, default or none).');
      if (n !== st.name && taken) return fail('There is already a key called ' + n + '.');
      const renamed = n !== st.name;
      const newPlan = plan && plan.value !== (x.plan || '') ? plan.value : null;
      if (value && value.trim().length < 20) return fail('Paste the whole ' + (x.kind === 'setup-token' ? 'token' : 'key') + ' — or leave it empty to keep the current one.');
      if (!renamed && !newPlan && !value) return fail('Nothing to change.');
      b.disabled = true; st.busy = true; fail('');
      const lines = [];
      try {
        if (renamed || newPlan) {
          const body2 = { action: 'account-edit', account: st.name };
          if (renamed) body2.newName = n;
          if (newPlan) body2.plan = newPlan;
          const op = await actOrThrow(body2);
          const end = op && op.id ? await waitOp(op.id) : null;
          if (end && end.state === 'failed') throw new Error(end.text || 'The change was refused');
          if (renamed) { lines.push('Renamed ' + st.name + ' to ' + n + (used.length ? ' — ' + and(used) + (used.length === 1 ? ' keeps' : ' keep') + ' using it.' : '.')); st.name = n; }
          if (newPlan) { lines.push('Plan ' + newPlan + ' — sessions started from now on get it.'); x.plan = newPlan; }
        }
        let row = null, fresh = null;
        if (value) {
          const kind = x.kind;
          const body3 = { name: st.name, kind, secret: value, replace: true, edit: true };
          if (kind === 'setup-token') body3.plan = plan ? plan.value : (x.plan || 'max');
          if (kind === 'key') body3.provider = p;
          fresh = await api('accounts', { method: 'POST', json: body3 });
          row = (fresh.accounts || []).find((y) => y.name === st.name) || null;
        }
        st.result = { lines, row, a: fresh ? { ...a, ...fresh } : a };
        if (!row) { toast(st.name + ': ' + lines.join(' ')); d.close(); } else paint();
      } catch (e) {
        st.busy = false;
        b.disabled = false;
        // What was already done stays done (a rename that went through keeps its new name here too).
        fail((lines.length ? lines.join(' ') + ' But ' : '') + (e.message || String(e)));
        head.querySelector('.h-title').textContent = 'Edit ' + st.name;
      }
      refresh(false);
    }, { primary: true, icon: 'check', data: { akEditSave: '' } });
    foot.append(h('span', { class: 'spacer' }), btn('Cancel', () => d.close(), { icon: 'x' }), save);
    d.replaceChildren(head, body, foot);
    name.focus();
  };
  paint();
}

function suggestName(a, p) {
  const base = p === 'vercel-ai-gateway' ? 'vercel' : p === 'google-stitch' ? 'stitch' : p === 'custom' ? 'example' : p;
  const taken = new Set((a.accounts || []).map((x) => x.name));
  let n = base, i = 2;
  while (taken.has(n)) n = base + '-' + i++;
  return n;
}
function seg(items, current, on, label) {
  return h('span', { class: 'segmented', role: 'group', 'aria-label': label },
    ...items.map(([v, l]) => h('button', { type: 'button', class: 'seg' + (v === current ? ' active' : ''), 'aria-pressed': String(v === current), 'data-ak-seg': v,
      on: { click: () => on(v) } }, l)));
}
/// The `doz account add` flag for a provider's key.
function provFlag(p) { return p === 'anthropic' ? ' --api-key' : p === 'openai' ? ' --openai-key' : ' --provider ' + p; }
const shq = (s) => (/^[A-Za-z0-9_./:@#=+-]+$/.test(s) ? s : "'" + s.replace(/'/g, "'\\''") + "'");
/// The failing key of this name and provider that a new key would replace in place (null: none — an ordinary add).
function replaceable(a, p, name) {
  return (a.accounts || []).find((x) => x.name === name && !isLogin(x) && isFailing(x) && providerOf(x) === p) || null;
}

/// Step 1's answer for a TOOL: the tools whose name the text names (a withdrawn one too — an existing sandbox of it still
/// needs its key; owner: shown as "coming soon"), the published ones first; each with the providers it can use.
function toolHits(a, ql) {
  if (ql.length < 2) return [];
  const titles = { ...(a.toolTitles || {}), ...(a.agentTitles || {}) };
  const ids = Object.keys(a.toolProviders || {}).filter((id) => (titles[id] || id).toLowerCase().includes(ql) || id.includes(ql));
  const pub = (id) => (a.agentTitles || {})[id] ? 0 : 1;
  return ids.sort((x, y) => pub(x) - pub(y) || (titles[x] || x).localeCompare(titles[y] || y)).slice(0, 3).map((id) => ({ id, title: titles[id] || id, providers: a.toolProviders[id], coming: pub(id) === 1 }));
}
/// A provider the text names exactly (its id or its name).
function providerHit(a, ql, order) {
  return order.find((p) => p === ql || title(a, p).toLowerCase() === ql || (p === 'custom' && ql === 'your own service')) || null;
}

function paintFlow() {
  const f = FLOW;
  if (!f) return;
  const a = f.a, d = f.d, p = f.provider;
  const steps = h('div', { class: 'ak-steps' }, ...['For what', 'The key', 'Check'].map((t, i) =>
    h('span', { class: i + 1 === f.step ? 'on' : i + 1 < f.step ? 'done' : '' }, (i + 1 < f.step ? '✓ ' : (i + 1) + ' ') + t)));
  const close = btn('Close', () => d.close(), { small: true, quiet: true, iconOnly: true, icon: 'x' });
  const body = h('div', { class: 'dlg-body ak-flow-body' });
  const foot = h('div', { class: 'dlg-foot dlg-buttons' });
  const head = h('div', { class: 'dlg-head ak-flow-head' },
    h('h2', { class: 'h-title', id: 'ak-flow-title' }, p && f.step > 1 ? (p === 'custom' ? 'Add a custom key' : 'Add ' + article(title(a, p)) + title(a, p) + ' key') : 'Add a key'), close);
  const pick = (pp, replace) => {
    f.provider = pp; f.step = 2;
    f.old = replace ? (a.accounts || []).find((x) => x.name === replace) || null : null;
    f.name = f.old ? f.old.name : '';
    if (f.old && (f.old.kind === 'setup-token' || f.old.kind === 'api-key')) f.kind = f.old.kind;
    f.source = pp === 'custom' ? 'custom' : f.source === 'custom' ? 'paste' : f.source;
    paintFlow();
  };
  if (f.step === 1) {
    const order = [...(a.providers || []), 'custom'];
    const q = h('input', { type: 'search', class: 'ak-in', placeholder: 'A tool or a provider — claude, codex, grok, openrouter…', 'aria-label': 'A tool or a provider', 'data-ak-search': '' });
    q.value = f.q;
    const hits = h('div', { class: 'ak-hits' });
    const grid = h('div', { class: 'ak-pgrid' });
    const rowsOf = (pp) => (a.accounts || []).filter((x) => providerOf(x) === pp && !isLogin(x));
    const paint = () => {
      const ql = f.q.trim().toLowerCase();
      const ph = providerHit(a, ql, order);
      const tools = ph ? [] : toolHits(a, ql);
      hits.replaceChildren(...tools.map((t) => h('div', { class: 'ak-tool-hit', 'data-ak-tool': t.id },
        h('div', { class: 'h' }, icon('terminal'), t.title + ' can use a key from',
          t.coming ? h('span', { class: 'tag outline', title: 'Not offered for new sandboxes yet — a sandbox you already have keeps using its key' }, 'coming soon') : null),
        ...t.providers.map((pp) => {
          const have = rowsOf(pp);
          const bad = have.find(isFailing);
          const users = [...new Set(have.flatMap((x) => x.usedBy || []))];
          const what = have.length ? 'you have ' + have.map((x) => x.name + ' — ' + statusWord(x, a)).slice(0, 2).join(', ') + (users.length ? ' · used by ' + users.slice(0, 2).join(', ') : '')
            : 'no key yet';
          const verb = bad ? 'Add again' : have.length ? 'Add another' : 'Add';
          return h('div', { class: 'ak-opt', 'data-ak-opt': pp },
            h('span', { class: 'ak-av', 'aria-hidden': 'true' }, title(a, pp).charAt(0)),
            h('b', null, title(a, pp), isGateway(a, pp) ? h('span', { class: 'tag outline' }, 'gateway') : null),
            h('small', null, what),
            btn(verb, () => pick(pp, bad ? bad.name : null), { small: true, primary: !!bad, data: { akPickOpt: pp } }));
        }))));
      grid.replaceChildren(...order.map((pp) => {
        const tl = toolsOf(a, pp);
        const match = !ql || pp === ph || (!ph && (title(a, pp).toLowerCase().includes(ql) || pp.includes(ql) || tl.some((t) => t.toLowerCase().includes(ql))));
        const have = rowsOf(pp).length;
        const sub = pp === 'custom' ? 'any host you name (a command)'
          : (have ? have + (have === 1 ? ' key' : ' keys') + ' · ' : '') + (tl.length ? 'for ' + tl.slice(0, 2).join(', ') + (tl.length > 2 ? '…' : '') : 'no tool yet');
        return h('button', { type: 'button', class: 'ak-pick' + (match ? '' : ' dim') + (pp === ph ? ' hit' : ''), 'data-ak-pick': pp, on: { click: () => pick(pp, null) } },
          h('span', { class: 'ak-av', 'aria-hidden': 'true' }, pp === 'custom' ? '+' : title(a, pp).charAt(0)), h('b', null, pp === 'custom' ? 'Your own service' : title(a, pp)), h('small', null, sub));
      }));
      or.hidden = !tools.length;
    };
    const or = h('div', { class: 'ak-or' }, 'Every provider');
    q.addEventListener('input', () => { f.q = q.value; paint(); });
    q.addEventListener('keydown', (ev) => {
      if (ev.key !== 'Enter') return;
      const ql = f.q.trim().toLowerCase();
      const ph = providerHit(a, ql, order);
      ev.preventDefault();
      if (ph) { pick(ph, null); return; }
      const t = toolHits(a, ql);
      if (t.length === 1 && t[0].providers.length === 1) { const bad = rowsOf(t[0].providers[0]).find(isFailing); pick(t[0].providers[0], bad ? bad.name : null); }
    });
    body.append(h('label', { class: 'field' }, h('span', null, 'Which tool is it for — or which provider?'), h('span', { class: 'filter-field ak-find' }, icon('search'), q),
      h('small', null, 'Type a tool to see the providers it can use and the keys you have for each. A gateway (OpenRouter, Vercel) reaches many models with one key.')), hits, or, grid);
    paint();
    foot.append(h('span', { class: 'spacer' }), btn('Cancel', () => d.close(), { icon: 'x' }));
    d.replaceChildren(head, h('div', { class: 'ak-flow-steps' }, steps), body, foot);
    q.focus();
    return;
  }
  if (f.step === 2) {
    if (!f.name) f.name = suggestName(a, p);
    const custom = p === 'custom';
    const choices = custom ? [['custom', 'Your own service']] : [['paste', 'Paste it'], ['1password', '1Password'], ['aws', 'AWS Secrets Manager'], ['command', 'A command']];
    if (p === 'openai' && state.chatgptSignIn) choices.splice(1, 0, ['chatgpt', 'ChatGPT sign-in']);
    if (!choices.some(([v]) => v === f.source)) f.source = choices[0][0];
    const name = h('input', { class: 'ak-in', autocomplete: 'off', spellcheck: 'false', 'aria-label': 'Name', 'data-ak-name': '' });
    name.value = f.name;
    const replaceNote = h('div', { 'data-ak-replace-slot': '' });
    const paintReplace = () => {
      const r = f.source === 'paste' ? replaceable(a, p, f.name) : null;
      const users = r ? r.usedBy || [] : [];
      replaceNote.replaceChildren(r ? callout('warn', { compact: true, icon: 'info', attrs: { 'data-ak-replaces': r.name },
        body: [h('b', null, 'Replaces ' + r.name), ', which ' + (r.state === 'rejected' ? 'was refused' : 'can’t be read') + '. '
          + (users.length ? and(users) + (users.length === 1 ? ' uses' : ' use') + ' it, so ' + (users.length === 1 ? 'its' : 'their') + ' next session uses the new key.' : 'No sandbox uses it now.')] }) : '');
    };
    name.addEventListener('input', () => { f.name = name.value.trim(); paintCmd(); paintReplace(); });
    body.append(replaceNote, h('div', { class: 'ak-two' },
      h('div', { class: 'field' }, h('span', null, 'Provider'), h('div', null, h('b', null, custom ? 'Your own service' : title(a, p)), ' ',
        btn('Change', () => { f.step = 1; paintFlow(); }, { small: true, quiet: true, icon: 'arrow-left' }))),
      h('label', { class: 'field' }, h('span', null, 'Name'), name, h('small', null, 'How it is called here and in doz commands: a-z 0-9 -.'))));
    paintReplace();
    if (!custom) body.append(h('div', { class: 'field' }, h('span', null, 'Where the key comes from'), seg(choices, f.source, (v) => { f.source = v; paintFlow(); }, 'Where the key comes from')));
    let cmdLine = null;
    const cmdBox = h('div', { class: 'ak-cmdbox' });
    const paintCmd = () => {
      if (!cmdLine) return;
      const line = cmdLine();
      cmdBox.replaceChildren(h('pre', { class: 'ak-cmd', 'data-ak-cmd': '' }, line), h('div', null, copyBtn(line, 'Copy', { small: true, icon: 'copy' })));
    };
    const pastes = f.source === 'paste' && secretEntryAllowed();
    let secret = null, plan = null;
    if (f.source === 'paste') {
      if (p === 'anthropic') {
        body.append(h('div', { class: 'field' }, h('span', null, 'Kind'),
          seg([['api-key', 'API key'], ['setup-token', 'Claude subscription (setup token)']], f.kind, (v) => { f.kind = v; paintFlow(); }, 'Kind'),
          h('small', null, f.kind === 'api-key' ? 'Billed to your Anthropic Console account. It starts sk-ant-api.' : 'Your Claude plan: run claude setup-token on this Mac and paste what it prints (valid a year).')));
        if (f.kind === 'setup-token') {
          plan = h('select', { class: 'ak-in', 'aria-label': 'Plan' }, ...['max', 'pro', 'team', 'enterprise'].map((x) => h('option', { value: x }, x)));
          plan.value = f.plan;
          plan.addEventListener('change', () => { f.plan = plan.value; });
          body.append(h('label', { class: 'field' }, h('span', null, 'Plan'), plan, h('small', null, 'Claude Code shows it and picks its default model by it.')));
        }
      }
      if (pastes) {
        secret = h('input', { class: 'ak-in', type: 'password', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off', 'data-secret': '1', placeholder: 'paste it here',
          'aria-label': p === 'anthropic' && f.kind === 'setup-token' ? 'Setup token' : 'API key' });
        body.append(h('label', { class: 'field' }, h('span', null, p === 'anthropic' && f.kind === 'setup-token' ? 'Setup token' : 'API key'), secret,
          h('small', null, 'Not shown, not kept in this page. ' + ((a.uncheckedProviders || []).includes(p) ? title(a, p) + ' has no key check, so it is saved as it is' : 'Checked with one tiny request to ' + title(a, p)) + ', then kept in your login keychain.')));
      } else {
        cmdLine = () => 'doz account add ' + (f.name || 'NAME') + (p === 'anthropic' && f.kind === 'setup-token' ? ' --setup-token --plan ' + f.plan : provFlag(p))
          + (replaceable(a, p, f.name) ? ' --force' : '');
        body.append(callout('info', { attrs: { 'data-secret-why': '1' }, title: 'Pasting a key here is turned off',
          body: [h('p', null, secretEntryWhy() + ' — in Terminal on this Mac (it asks for the key and does not echo it):'), cmdBox] }));
      }
    } else if (f.source === 'chatgpt') {
      cmdLine = () => 'doz account add ' + (f.name || 'NAME') + ' --chatgpt';
      body.append(h('p', { class: 'muted' }, 'Codex on your ChatGPT plan. Your browser opens on OpenAI’s sign-in — Dozable’s own sign-in; your Mac’s Codex login is not touched. It runs from Terminal:'), cmdBox);
    } else if (f.source === 'custom') {
      const host = h('input', { class: 'ak-in', spellcheck: 'false', 'aria-label': 'Host it may go to' }); host.value = f.host;
      const env = h('input', { class: 'ak-in', spellcheck: 'false', 'aria-label': 'Variable in the sandbox' }); env.value = f.envVar;
      const hdr = h('select', { class: 'ak-in', 'aria-label': 'Sent as' }, h('option', { value: 'bearer' }, 'Authorization: Bearer KEY'), h('option', { value: 'x-api-key' }, 'x-api-key: KEY'));
      hdr.value = f.header;
      host.addEventListener('input', () => { f.host = host.value.trim(); paintCmd(); });
      env.addEventListener('input', () => { f.envVar = env.value.trim(); paintCmd(); });
      hdr.addEventListener('change', () => { f.header = hdr.value; paintCmd(); });
      cmdLine = () => 'doz account add ' + (f.name || 'NAME') + ' --custom --host ' + shq(f.host || 'HOST') + ' --env-var ' + shq(f.envVar || 'VAR')
        + (f.header === 'bearer' ? ' --bearer' : ' --header x-api-key');
      body.append(h('div', { class: 'ak-two' }, h('label', { class: 'field' }, h('span', null, 'Host it may go to'), host), h('label', { class: 'field' }, h('span', null, 'Variable in the sandbox'), env)),
        h('label', { class: 'field' }, h('span', null, 'Sent as'), hdr),
        h('p', { class: 'muted' }, 'A custom key names the hosts it may go to, so it is added in Terminal (it asks for the key):'), cmdBox);
    } else {
      const ex = f.source === '1password' ? 'op://VAULT/ITEM/FIELD' : f.source === 'aws' ? 'aws:arn:aws:secretsmanager:REGION:ACCOUNT:secret:NAME' : '/usr/local/bin/my-token';
      const ref = h('input', { class: 'ak-in', spellcheck: 'false', placeholder: ex, 'aria-label': f.source === '1password' ? '1Password reference' : f.source === 'aws' ? 'Secret ARN' : 'The program and its arguments', 'data-ak-ref': '' });
      ref.value = f.ref;
      ref.addEventListener('input', () => { f.ref = ref.value.trim(); paintCmd(); });
      cmdLine = () => 'doz account add ' + (f.name || 'NAME') + provFlag(p) + (f.source === 'command' ? ' --from-command ' + shq(f.ref || ex) : ' --from ' + shq(f.ref || ex))
        + ((a.accounts || []).some((x) => x.name === f.name && !isLogin(x)) ? ' --force' : '');
      body.append(h('label', { class: 'field' }, h('span', null, f.source === '1password' ? '1Password reference' : f.source === 'aws' ? 'Secret ARN (optionally #jsonKey)' : 'The program and its arguments (never a shell)'), ref,
        h('small', null, f.source === '1password' ? 'In 1Password: the field’s … menu › Copy Secret Reference.' : f.source === 'aws' ? 'The AWS CLI on this Mac reads it, with your AWS_PROFILE.' : 'Its output is the key.')),
        h('p', { class: 'muted' }, 'Dozable reads the key on this Mac each time a sandbox needs it (kept in memory, never stored). Because that runs '
          + (f.source === '1password' ? 'op' : f.source === 'aws' ? 'aws' : 'a program') + ' as you, it is added in Terminal; this page then shows it and can read it again:'), cmdBox);
    }
    paintCmd();
    const err = h('div', { class: 'dlg-error', role: 'alert', 'data-ak-error': '' }, f.error || '');
    let mk = null;
    if (!custom && pastes) {
      const cur = (a.accounts || []).find((x) => providerOf(x) === p && x.isDefault);
      const keeps = cur && f.old && cur.name === f.old.name;
      mk = h('input', { type: 'checkbox', 'data-ak-make-default': '' });
      mk.checked = f.makeDefault ?? (!cur || keeps);
      mk.addEventListener('change', () => { f.makeDefault = mk.checked; });
      body.append(h('label', { class: 'field check' }, mk, h('span', null, keeps ? 'Keep it ' + title(a, p) + '’s default'
        : 'Make it ' + title(a, p) + '’s default' + (cur ? ' (now: ' + shownName(cur) + ')' : ' — there is none yet'))));
    }
    body.append(err);
    foot.append(btn('Back', () => { f.step = 1; f.error = ''; paintFlow(); }, { quiet: true, icon: 'arrow-left' }), h('span', { class: 'spacer' }),
      btn(pastes ? 'Cancel' : 'Done', () => d.close(), { icon: pastes ? 'x' : 'check' }));
    if (pastes) {
      const go = btn('Add and check', async () => {
        const value = secret.value;
        secret.value = '';                                        // gone from the page before the request
        const n = (f.name || '').trim();
        if (!NAME.test(n) || n === 'default' || n === 'none') { f.error = 'The name: 1–40 of a-z 0-9 - (not default or none).'; err.textContent = f.error; return; }
        if (value.trim().length < 20) { f.error = 'Paste the whole ' + (f.kind === 'setup-token' && p === 'anthropic' ? 'token' : 'key') + '.'; err.textContent = f.error; return; }
        const kind = p === 'anthropic' ? f.kind : p === 'openai' ? 'openai-key' : 'key';
        const body2 = { name: n, kind, secret: value };
        if (kind === 'setup-token') body2.plan = f.plan;
        if (kind === 'key') body2.provider = p;
        // A failing key of this name is replaced in place (the server refuses it for one that works).
        const old = replaceable(a, p, n);
        if (old) body2.replace = true;
        f.step = 3; f.result = { checking: true, name: n }; f.error = ''; paintFlow();
        try {
          const r = await api('accounts', { method: 'POST', json: body2 });
          const row = (r.accounts || []).find((x) => x.name === n);
          if (mk && mk.checked && row && !row.isDefault) { try { await actOrThrow({ action: 'account-default', account: n }); row.isDefault = true; } catch (_) { /* said on the page */ } }
          f.a = { ...a, ...r };
          // Its old copies (the same fingerprint as the key it replaced) that still fail: offered for removal.
          const copies = old && old.fingerprint ? (r.accounts || []).filter((x) => x.name !== n && x.fingerprint === old.fingerprint && isFailing(x)) : [];
          f.result = { name: n, row, replaced: !!old, copies };
        } catch (e) {
          f.result = { name: n, error: e.message || String(e) };
        }
        if (FLOW === f) paintFlow();
        refresh(false);
      }, { primary: true, icon: 'key-round' });
      go.dataset.akAdd = '';
      foot.append(go);
    }
    d.replaceChildren(head, h('div', { class: 'ak-flow-steps' }, steps), body, foot);
    (secret || name).focus();
    return;
  }
  // 3. the check's outcome, where you are — and what follows from it (the old copy, the default).
  const r = f.result || {};
  let res;
  if (r.checking) res = [h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), h('div', null, h('b', null, 'Checking with ' + title(a, p) + '…'), h('div', { class: 'muted' }, 'One tiny request, then it is kept in your login keychain.'))];
  else if (r.error) res = [statusPill(['fail', 'circle-x', 'Refused', null]), h('div', null, h('b', null, 'Not added: ' + r.error), h('div', { class: 'muted' }, 'Nothing was saved. Check you copied the whole key, then paste it again.'))];
  else {
    const s = r.row ? statusOf(r.row, f.a) : ['ok', 'circle-check', 'Works', null];
    const users = r.row ? r.row.usedBy || [] : [];
    const line = (s[2] === 'Works' ? title(a, p) + ' accepted it; it is in your login keychain.'
      : s[2] === 'No check for this provider' ? title(a, p) + ' has no key check, so it is used as is; a sandbox’s first request will tell.'
      : 'Saved' + (s[3] ? ' — ' + s[3] : '') + '.') + (users.length ? ' ' + and(users) + (users.length === 1 ? ' uses' : ' use') + ' it from ' + (users.length === 1 ? 'its' : 'their') + ' next session.' : '');
    res = [statusPill(s), h('div', null, h('b', null, r.name + (s[0] === 'fail' ? ' is saved, but ' + s[2].toLowerCase() + '.' : s[2] === 'Works' ? ' works.' : ' is ready.')), h('div', { class: 'muted' }, line))];
  }
  body.append(h('div', { class: 'ak-result', role: 'status', 'data-ak-result': r.checking ? 'checking' : r.error ? 'refused' : 'done' }, ...res));
  if (!r.checking && !r.error) {
    for (const c of r.copies || []) {
      body.append(h('div', { class: 'ak-follow', 'data-ak-follow': 'remove' }, icon('trash-2'),
        h('b', null, c.name + ' is the old copy — and still ' + (c.state === 'rejected' ? 'refused' : 'can’t be read')),
        h('div', { class: 'd' }, (c.usedBy || []).length ? and(c.usedBy) + ' still ' + (c.usedBy.length === 1 ? 'uses' : 'use') + ' it — change ' + (c.usedBy.length === 1 ? 'its key' : 'their key') + ' first.' : 'No sandbox uses it. Remove it now?'),
        btn('Remove ' + c.name + '…', () => { d.close(); confirmRemove(c); }, { small: true, danger: true, icon: 'trash-2' })));
    }
    if (r.row && !r.row.isDefault && p !== 'custom') {
      body.append(h('div', { class: 'ak-follow', 'data-ak-follow': 'default' }, icon('circle-check'), h('b', null, 'Make it ' + title(a, p) + '’s default?'),
        h('div', { class: 'd' }, 'Sandboxes that follow ' + title(a, p) + '’s default then use it.'),
        btn('Make it the default', async (ev) => {
          ev.currentTarget.disabled = true;
          try { await actOrThrow({ action: 'account-default', account: r.name }); r.row.isDefault = true; paintFlow(); } catch (e) { toast(e.message || String(e), true); }
        }, { small: true, icon: 'check' })));
    }
  }
  // Never append a null: the DOM writes it as the text "null".
  foot.append(...[r.error ? btn('Paste again', () => { f.step = 2; paintFlow(); }, { primary: true, icon: 'key-round' }) : null, h('span', { class: 'spacer' }),
    r.checking ? null : btn(r.error ? 'Cancel' : 'Done', () => d.close(), { primary: !r.error, icon: r.error ? 'x' : 'check' })].filter(Boolean));
  d.replaceChildren(head, h('div', { class: 'ak-flow-steps' }, steps), body, foot);
}
