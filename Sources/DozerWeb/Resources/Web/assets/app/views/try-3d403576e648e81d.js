// views/try — Quick try (617; the owner's redesign, mock 616 quick-try-v2, then the owner's feedback on the built one):
// the wizards' modal over the app, like onboarding (#/try, #/try/AGENT; the app stays visible behind the scrim; Esc or
// Close returns to where it was opened). Two panes: on the left a search box (`doz search`'s matching + fuzzy,
// core/agent-search.js), the filter pills (Ready · Open source · Current · Headless · Through a gateway — AND), the
// count and the cards/list toggle (remembered), then the results, superseded last; on the right the chosen agent,
// INFORMATION ONLY (what a published recipe page shows: description, versions, tags, what it can reach, the command)
// and a Try button. Try opens the SETUP — a smaller modal holding every prerequisite (the key, what is not offered,
// the image, the plan) and Start. Keyboard: / searches, ↑/↓ move through the results, Enter opens the setup. Below
// 760 px the panes stack (a back control).
//
// The same decisions as `doz try`: the host's planner (`POST plan`, purpose try) names it try-AGENT, gives it a NEW
// EMPTY folder of its own, Locked + its own model, the agent's own base and a key it can use. Browsing prepares
// NOTHING (owner: no build per recipe looked at); Start makes it with the ordinary `create` action (trial), starts it
// (the image prepared then, its progress in the terminal area) and opens its session. A try's page then offers
// Sleep · Delete · Keep (`tryBar`, views/sandbox.js).
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { icon, mark } from '../dom/icons-3758b5050701761c.js';
import { api } from '../core/api-2e66c14d90f7f83a.js';
import { rank, suggest } from '../core/agent-search-a05f165f3681cc81.js';
import { actOrThrow, prepRunning, waitOp } from '../core/operations-73b26effbe04935d.js';
import { secretEntryAllowed } from '../core/settings-70247ce370cb44d9.js';
import { state } from '../core/state-450cb6573a620304.js';
import { btn } from '../components/button-a9b0357c06093925.js';
import { callout } from '../components/callout-e08cdc5a5cc374bb.js';
import { startWithBootView } from '../components/lifecycle-6df34f5d0e7faaae.js';
import { renderModal, wizardCloseRequest } from '../components/modal-4bece47591b5e2c7.js';
import { pageFailure, toast } from '../components/notices-82f2fa6c4cb061e0.js';
import { planCommand, reachList } from '../components/plan-view-71865692ab7fdc06.js';
import { prepCard } from '../components/prep-card-23eefbc3cb5edd13.js';

const AGENT_ID = /^[a-z0-9][a-z0-9-]{0,39}$/;
const VIEW_KEY = 'doz.tryView';
/// The pills, in order: [id, label, the test].
const PILLS = [
  ['ready', 'Ready', (a) => !!a.ready],
  ['open', 'Open source', (a) => !!a.openSource],
  ['current', 'Current', (a) => a.current !== false],
  ['headless', 'Headless', (a) => !!a.headless],
  ['gateway', 'Through a gateway', (a) => !!a.gateway],
];

/// "4 days" → "4 days ago"; "today" stays.
const ago = (age) => age === 'today' ? 'today' : age + ' ago';

function savedView() { try { return localStorage.getItem(VIEW_KEY) === 'list' ? 'list' : 'cards'; } catch (_) { return 'cards'; } }

/// The modal's view (the router passes the agent of `#/try/AGENT`).
export async function viewTry() {
  const want = state.tryAgent && AGENT_ID.test(state.tryAgent) ? state.tryAgent : null;
  const old = state.tr;
  if (!old || old.asked !== want) {
    const catalog = await api('try');
    const first = catalog.agents.find((a) => a.id === want) || catalog.agents.find((a) => a.ready) || catalog.agents[0] || null;
    // The search, the pills, the view and the pane survive a re-read (a key saved, Check again).
    state.tr = { asked: want, catalog, agent: first ? first.id : null, error: '', creating: false,
      q: old ? old.q : '', f: old ? old.f : new Set(), view: old ? old.view : savedView(), detail: old ? old.detail : !!want };
  }
  return tryNode();
}

/// Agents (and the coming ones) as the search sees them.
function entries() {
  const c = state.tr.catalog;
  return [...c.agents.map((a) => ({ ...a, kind: 'agent' })), ...c.coming.map((x) => ({ ...x, kind: 'coming', tags: [], current: true }))];
}

/// The results: the search's matches that pass every pill — best match first, superseded and coming last.
function hits() {
  const tr = state.tr;
  const pills = PILLS.filter(([id]) => tr.f.has(id));
  const all = entries();
  return all.map((e, i) => ({ e, i, r: rank(e, tr.q) }))
    .filter(({ e, r }) => r > 0 && (!pills.length || (e.kind === 'agent' && pills.every(([, , t]) => t(e)))))
    .sort((x, y) => (x.e.kind === 'coming') - (y.e.kind === 'coming') || (x.e.current === false) - (y.e.current === false) || y.r - x.r || x.i - y.i)
    .map(({ e }) => e);
}

function current() {
  const tr = state.tr;
  return tr && entries().find((a) => a.id === tr.agent);
}

function rerender() { if (state.modal === 'try') renderModal(false); }

/// 594's preparations arrive over SSE: the card of the chosen agent's image is drawn in place.
export function renderTryPrep() {
  const box = document.querySelector('[data-try-prep]');
  const a = current();
  if (!box || !a || a.kind !== 'agent') return;
  box.replaceChildren(...prepNodes(a));
}

function prepNodes(a) {
  const p = (state.preps || []).find((x) => x.image === a.plan.image.name);
  if (p && (prepRunning(p) || p.error)) return [prepCard(p)];
  if (a.plan.image.state === 'unprepared' && !(p && p.state === 'done')) {
    return [h('span', null, (a.plan.image.title || a.plan.image.name) + ' — prepared when you press Start (minutes the first time; it needs the network); the progress shows in its terminal area.')];
  }
  return [h('span', { 'data-try-ready': '' }, (a.plan.image.title || a.plan.image.name) + ' — ready.')];
}

// ── the left pane ────────────────────────────────────────────────────────────

function select(id, opts = {}) {
  const tr = state.tr;
  if (tr.agent !== id) { tr.error = ''; }
  tr.agent = id;
  tr.asked = id; state.tryAgent = id;
  history.replaceState(null, '', '#/try/' + id);
  if (opts.detail) tr.detail = true;
  paint({ focusItem: !!opts.focusItem });
}

function resultItem(a) {
  const tr = state.tr, sel = a.id === tr.agent;
  const sub = a.kind === 'coming' ? 'coming' : [a.version, a.age ? ago(a.age) : null, a.current === false ? 'superseded' : null].filter(Boolean).join(' · ');
  const b = h('button', { type: 'button', role: 'option', class: 'qt-item' + (a.current === false ? ' superseded' : '') + (a.kind === 'coming' ? ' coming' : ''),
    'aria-selected': String(sel), tabindex: sel ? '0' : '-1', 'data-try-agent': a.id, ...(a.kind === 'coming' ? { 'data-try-coming': a.id } : {}) },
    mark(a.icon),
    h('span', { class: 'tp' }, h('span', { class: 't' }, a.title), h('span', { class: 'p' }, a.publisher)),
    h('span', { class: 'v' }, sub),
    a.ready ? h('span', { class: 'ready', title: 'Its key is here: ready to start' }, icon('circle-check')) : h('span', { class: 'ready-gap' }));
  b.addEventListener('click', () => select(a.id, { detail: true }));
  return b;
}

function resultsNodes() {
  const tr = state.tr, list = hits();
  if (!list.length) {
    const s = suggest(tr.q, entries());
    return [h('div', { class: 'qt-empty', 'data-try-empty': '' },
      icon('search'),
      h('p', null, 'No agent matches' + (tr.q.trim() ? ' “' + tr.q.trim() + '”' : '') + (tr.f.size ? ' with these filters' : '') + '.'),
      s ? h('p', null, 'Did you mean ', h('button', { type: 'button', class: 'linkish', on: { click: () => { tr.q = s.id; tr.f.clear(); paint({ keepSearch: false }); } } }, s.title), '?') : null,
      btn('Clear search and filters', () => { tr.q = ''; tr.f.clear(); paint({ keepSearch: false }); }, { small: true, icon: 'x' }),
      h('p', { class: 'muted' }, 'Missing an agent? ', h('code', null, 'doz search NAME'), ' says whether it is coming.'))];
  }
  if (!list.some((a) => a.id === tr.agent)) tr.agent = list[0].id;
  return list.map(resultItem);
}

function countText() {
  const n = hits().length, all = entries().filter((e) => e.kind === 'agent').length;
  const agents = hits().filter((e) => e.kind === 'agent').length;
  return n === entries().length || (!state.tr.q.trim() && !state.tr.f.size) ? all + ' agents' : agents + ' of ' + all + ' agents' + (n > agents ? ' · ' + (n - agents) + ' coming' : '');
}

function leftPane() {
  const tr = state.tr;
  const input = h('input', { type: 'search', placeholder: 'Search agents — name, maker, tag:headless', autocomplete: 'off', spellcheck: 'false',
    'aria-label': 'Search agents', 'data-try-search': '', value: tr.q });
  input.addEventListener('input', () => { tr.q = input.value; paint({ keepSearch: true }); });
  input.addEventListener('keydown', (ev) => {
    if (ev.key === 'Escape') {
      ev.preventDefault(); ev.stopPropagation();
      if (input.value) { input.value = ''; tr.q = ''; paint({ keepSearch: true }); } else wizardCloseRequest();
    }
  });
  const pills = PILLS.map(([id, label]) => h('button', { type: 'button', class: 'qt-pill', 'aria-pressed': String(tr.f.has(id)), 'data-try-pill': id,
    on: { click: () => { if (tr.f.has(id)) tr.f.delete(id); else tr.f.add(id); paint({}); } } }, id === 'ready' ? icon('key-round') : null, label));
  const seg = h('span', { class: 'qt-seg', role: 'group', 'aria-label': 'View' },
    ...[['cards', 'Cards', 'layout-grid'], ['list', 'List', 'list']].map(([v, label, ic]) => h('button', { type: 'button', 'aria-label': label, title: label,
      'aria-pressed': String(tr.view === v), 'data-try-view': v,
      on: { click: () => { tr.view = v; try { localStorage.setItem(VIEW_KEY, v); } catch (_) { /* no storage: this visit only */ } paint({}); } } }, icon(ic))));
  return h('section', { class: 'qt-left', 'aria-label': 'Agents' },
    h('div', { class: 'qt-search' },
      h('label', { class: 'qt-box' }, icon('search'), input, h('span', { class: 'qt-kbd', 'aria-hidden': 'true' }, '/')),
      h('div', { class: 'qt-pills', role: 'group', 'aria-label': 'Filters' }, ...pills),
      h('div', { class: 'qt-bar' }, h('span', { 'data-try-count': '' }, countText()), h('span', { class: 'qt-gap' }), seg)),
    h('div', { class: 'qt-results ' + tr.view, role: 'listbox', 'aria-label': 'Agents', 'data-try-results': '' }, ...resultsNodes()));
}

// ── the right pane: information only ─────────────────────────────────────────
// 617 (owner): "similar to what we will eventually publish" — browsing is the first intention. What it is, its
// versions and tags, what it can reach and the command; no key, no plan form. Try opens the setup (below).

function sect(title, ...body) { return h('div', { class: 'qt-sect' }, h('h3', null, title), ...body); }

/// Tags no pill already says (its other capabilities), as the directory names them.
const TAG_WORDS = { 'api-key': 'an API key', 'vendor-sign-in': 'its maker’s sign-in', 'multi-vendor-models': 'many models', 'no-account': 'no account',
                    'free-tier': 'a free tier', status: 'reports its status', resume: 'resumes a conversation', musl: 'runs on Alpine' };

function detailNodes() {
  const tr = state.tr, a = current();
  const back = btn('All agents', () => { tr.detail = false; paint({}); }, { small: true, quiet: true, icon: 'arrow-left' });
  back.classList.add('qt-back');
  if (!a) return [back, h('div', { class: 'qt-empty' }, h('p', null, 'Nothing selected.'))];
  const head = h('div', { class: 'qt-head' }, mark(a.icon, 'lg'),
    h('div', null, h('h2', { 'data-try-title': '' }, a.title), h('div', { class: 'p' }, a.publisher + (a.kind === 'agent' ? ' · ' + (a.openSource ? 'open source' : 'closed source') : ''))));
  if (a.kind === 'coming') {
    return [back, head, callout('info', { body: 'Coming — ' + a.reason }),
      h('p', { class: 'muted' }, 'Dozer cannot run it yet. ', h('code', null, 'doz search ' + a.id), ' says when that changes.')];
  }
  const facts = h('div', { class: 'qt-facts' },
    h('span', { class: 'tag ' + (a.current === false ? 'warn' : 'ok') }, a.current === false ? 'superseded' : 'current'),
    a.headless ? h('span', { class: 'tag outline' }, 'headless') : null,
    a.gateway ? h('span', { class: 'tag outline' }, 'through a gateway') : null,
    ...(a.tags || []).filter((t) => TAG_WORDS[t]).map((t) => h('span', { class: 'tag outline', 'data-try-tag': t }, TAG_WORDS[t])));
  const by = a.supersededBy && state.tr.catalog.agents.find((x) => x.id === a.supersededBy);
  const standing = a.current === false
    ? callout('warn', { attrs: { 'data-try-standing': a.id }, title: by ? 'Superseded by ' + by.title : 'Not current with its maker',
      body: h('span', null, (a.standing || '').replace(/^Superseded by [^—]*—\s*/, '') + ' ', by ? h('button', { type: 'button', class: 'linkish', on: { click: () => select(by.id, { detail: true }) } }, 'See ' + by.title) : null) })
    : null;
  const versions = h('dl', { class: 'qt-plan' },
    h('dt', null, 'Dozer installs'), h('dd', { 'data-try-latest': a.id }, (a.version || '—') + (a.age ? ' · released ' + ago(a.age) : '')),
    a.latest ? h('dt', null, 'Its newest') : null, a.latest ? h('dd', { class: 'muted' }, a.latest.replace(/^latest:?\s*/, '')) : null,
    h('dt', null, 'Base'), h('dd', null, a.base || '—'));
  const tryBtn = btn('Try ' + a.title + '…', () => openSetup(a), { primary: true, lg: true, icon: 'rocket', title: 'Set it up and start it (Enter)' });
  tryBtn.dataset.tryOpen = '';
  return [back, head, facts,
    a.description ? h('p', { class: 'qt-desc', 'data-try-description': '' }, a.description) : null,
    standing,
    sect('Versions', versions),
    sect('What it can reach', reachList(a.plan.reach)),
    sect('The same, in a terminal', planCommand(a.plan)),
    h('div', { class: 'qt-foot' }, h('span', { class: 'qt-gap' }), h('span', { class: 'qt-note' }, 'Enter'), tryBtn)].filter(Boolean);   // (replaceChildren writes a null as "null")
}

// ── Try: the setup — a smaller modal over the Quick try ──────────────────────
// 617 (owner): every prerequisite lives here — the key (one there, one saved now, one kept outside: the command),
// what is not offered (a sign-in, a gateway), the image, the plan — and the final Start. Cancel (or Esc) leaves
// nothing behind. Later: customising the try (the clipboard bridge off, …) gets a section of its own here.
//
// The key that did not work (owner): a key saved for an agent the provider's DEFAULT account cannot serve (pi, whose
// Anthropic default is the Mac's Claude Code login — pi takes API keys only) was saved, then the plan asked the
// default again and still found none. The setup now plans WITH the account it uses — the one just saved, one chosen,
// or (the default being unusable) the first usable one — as `doz try` does ("this try uses it").

const SETUP = { d: null, a: null, plan: null, account: null, busy: false, error: '' };

/// The accounts the agent can use, the provider's default first.
function usable(a) { return [...(a.usableAccounts || [])].sort((x, y) => (y.isDefault ? 1 : 0) - (x.isDefault ? 1 : 0)); }

async function replan(account) {
  const a = SETUP.a;
  SETUP.account = account || null;
  SETUP.plan = await api('plan', { method: 'POST', json: { purpose: 'try', agent: a.id, ...(account ? { account } : {}) } });
}

function keyProblem(plan) { return (plan.problems || []).find((p) => p.code === 'key'); }

async function openSetup(a) {
  if (SETUP.d) return;
  SETUP.a = a; SETUP.plan = a.plan; SETUP.account = null; SETUP.busy = false; SETUP.error = '';
  const d = h('dialog', { class: 'dlg try-setup', 'aria-labelledby': 'try-setup-title', 'data-try-setup': a.id });
  d.addEventListener('close', () => { d.remove(); SETUP.d = null; });
  SETUP.d = d;
  document.body.append(d);
  d.showModal();
  // The default cannot serve it, but a key it can use is here: use that one.
  const u = usable(a);
  if (keyProblem(a.plan) && u.length) { try { await replan(u[0].name); } catch (e) { SETUP.error = e.message || String(e); } }
  paintSetup();
}

function paintSetup() {
  const d = SETUP.d, a = SETUP.a, plan = SETUP.plan;
  if (!d) return;
  const missing = keyProblem(plan);
  const blocked = (plan.problems || []).filter((p) => p.code !== 'key');
  const close = h('button', { type: 'button', class: 'btn sm quiet icon-only', title: 'Cancel', 'aria-label': 'Cancel', on: { click: () => d.close() } }, icon('x'));
  const start = btn('Start', () => tryCreate(start), { primary: true, icon: 'rocket' });
  start.dataset.tryCreate = '';
  start.disabled = !!missing || blocked.length > 0 || SETUP.busy;
  const cancel = btn('Cancel', () => d.close(), { quiet: true, icon: 'x' });
  d.replaceChildren(h('form', { method: 'dialog', on: { submit: (ev) => { ev.preventDefault(); if (!start.disabled) tryCreate(start); } } },
    h('div', { class: 'dlg-head' }, mark(a.icon), h('h2', { class: 'h-title', id: 'try-setup-title' }, 'Try ' + a.title), close),
    h('div', { class: 'dlg-body' },
      h('p', { class: 'sub' }, 'A fresh sandbox, ' + plan.name + ': a new empty folder of its own, the network locked to its model, your key never inside.'),
      sect('Key', ...keyNodes(a, plan, missing)),
      sect('Image', h('div', { class: 'try-prep', 'data-try-prep': '' }, ...prepNodes({ ...a, plan }))),
      sect('The plan', planFacts(a, plan)),
      ...blocked.map((p) => callout('bad', { compact: true, body: p.text + (p.fix ? ' — ' + p.fix : '') })),
      SETUP.error ? callout('bad', { compact: true, attrs: { 'data-try-error': '' }, body: SETUP.error }) : null),
    h('div', { class: 'dlg-foot dlg-buttons' }, h('span', { class: 'why' }, missing ? 'Add a key first' : ''), cancel, start)));
  const f = d.querySelector('[data-try-key]');
  (f || (start.disabled ? cancel : start)).focus();
}

/// The key part: the one this try uses (and, when it can use several, a choice), or what it needs.
function keyNodes(a, plan, missing) {
  const u = usable(a);
  const nodes = [];
  if (!missing) {
    const acc = plan.account;
    nodes.push(h('p', { class: 'try-key', 'data-try-key-ok': '' }, icon('circle-check'), ' ',
      acc && acc.name ? h('strong', null, acc.name) : 'none needed', acc && acc.sourceLabel ? ' — ' + acc.sourceLabel : '',
      acc && acc.name ? ' — the sandbox only ever sees a placeholder.' : ''));
    if (u.length > 1) {
      const sel = h('select', { 'aria-label': 'The key this try uses', 'data-try-account': '' },
        ...u.map((x) => h('option', { value: x.name }, x.name + (x.source ? ' — ' + x.source : '') + (x.isDefault ? ' (default)' : ''))));
      sel.value = (acc && acc.name) || u[0].name;
      sel.addEventListener('change', async () => { await replan(sel.value).catch((e) => { SETUP.error = e.message || String(e); }); paintSetup(); });
      nodes.push(h('label', { class: 'field' }, h('span', null, 'Use another key'), sel));
    }
    return nodes;
  }
  const c = a.card;
  if (!c) return [callout('bad', { compact: true, body: missing.text + (missing.fix ? ' — ' + missing.fix : '') })];
  nodes.push(h('h4', null, c.title));
  for (const o of c.options) {
    if (o.kind === 'paste') {
      if (secretEntryAllowed()) {
        const field = h('input', { type: 'password', autocomplete: 'off', spellcheck: 'false', 'data-try-key': '', placeholder: 'paste the key', 'aria-label': o.label });
        const save = btn('Save the key', () => saveKey(field, save), { small: true, icon: 'key-round' });
        field.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); saveKey(field, save); } });
        nodes.push(h('div', { class: 'try-option' }, h('div', null, h('strong', null, o.label), h('div', { class: 'muted' }, o.consequence)), h('div', { class: 'try-paste' }, field, save)));
      } else {
        nodes.push(h('div', { class: 'try-option' }, h('strong', null, o.label), h('div', { class: 'muted' }, 'Pasting keys here is off (ui.allow_secret_entry) — in a terminal on this Mac:'),
          h('code', null, c.addCommand || 'doz account add NAME')));
      }
    } else if (o.kind === 'source') {
      nodes.push(h('div', { class: 'try-option' }, h('strong', null, o.label), h('div', { class: 'muted' }, o.consequence + ' — set up in a terminal on this Mac:'),
        h('code', null, (c.addCommand || 'doz account add NAME') + ' --from op://VAULT/ITEM/FIELD'),
        h('div', { class: 'muted' }, 'or --from aws:arn:… or --from-command \'…\'; then press Check again.')));
    } else {
      nodes.push(h('div', { class: 'try-option' }, h('strong', null, o.label), h('div', { class: 'muted' }, o.consequence)));
    }
  }
  for (const n of c.notOffered) nodes.push(h('div', { class: 'try-option not-offered', 'data-try-not-offered': '' }, h('strong', null, 'Not offered here'), h('div', { class: 'muted' }, n)));
  if (c.getKey) nodes.push(h('p', { class: 'muted' }, c.getKey));
  nodes.push(h('div', null, btn('Check again', () => recheck(), { small: true, quiet: true, icon: 'refresh-cw' })));
  return [h('div', { class: 'try-need', 'data-try-need': '' }, ...nodes)];
}

/// A pasted key: saved as an account of the provider (a free name), then THIS try plans with it.
async function saveKey(field, button) {
  const a = SETUP.a;
  const secret = field.value.trim();
  field.value = '';                                   // emptied before the request
  if (!secret || SETUP.busy) return;
  button.disabled = true;
  SETUP.error = '';
  try {
    const p = a.provider;
    const kind = p === 'anthropic' ? 'api-key' : p === 'openai' ? 'openai-key' : 'key';
    const taken = new Set(((await api('accounts')).accounts || []).map((x) => x.name));
    const base = p || a.id;
    let name = base;
    for (let n = 2; taken.has(name); n++) name = base + '-' + n;
    await api('accounts', { method: 'POST', json: { name, kind, secret, ...(kind === 'key' ? { provider: p } : {}) } });
    toast('Key saved — ' + name + ' (' + (a.providerTitle || p) + ')');
    await replan(name);
    refreshCatalog();
  } catch (e) { SETUP.error = e.message || String(e); }
  paintSetup();
}

/// Check again (a key set up in a terminal): the catalog read again, and the try planned with a key it can use.
async function recheck() {
  SETUP.error = '';
  try {
    const catalog = await api('try');
    state.tr.catalog = catalog;
    const a = catalog.agents.find((x) => x.id === SETUP.a.id) || SETUP.a;
    SETUP.a = a;
    SETUP.plan = a.plan;
    const u = usable(a);
    if (keyProblem(a.plan) && u.length) await replan(u[0].name);
    paint({});
  } catch (e) { SETUP.error = e.message || String(e); }
  paintSetup();
}

function refreshCatalog() {
  api('try').then((catalog) => { if (state.tr) { state.tr.catalog = catalog; paint({}); } }).catch(() => { /* the list stays */ });
}

function planFacts(a, p) {
  const lines = (kind) => p.reach.filter((r) => r.kind === kind).map((r) => r.text);
  const fact = (k, v) => [h('dt', null, k), h('dd', null, v)];
  return h('dl', { class: 'qt-plan try-facts' },
    ...fact('Name', p.name),
    ...fact('Base', a.base || '—'),
    ...fact('Network', 'Locked — only its model (' + (lines('model')[0] || 'its model') + ')'),
    ...fact('Folder', lines('folder')[0] || '—'),
    ...fact('Your Mac', lines('bridge').join(' · ') || '—'));
}

/// Start → the ordinary `create` action (a try: `trial`, its new folder, the account the setup chose), then the start
/// with the boot view, which opens its own session in a terminal on its page.
async function tryCreate(button) {
  const a = SETUP.a, plan = SETUP.plan;
  if (!a || SETUP.busy) return;
  SETUP.busy = true;
  button.disabled = true;
  const c = plan.create;
  try {
    const op = await actOrThrow({ action: 'create', sandbox: plan.name, image: c.image, trial: true,
      ...(c.network ? { network: c.network } : {}), ...(c.workspace ? { workspace: c.workspace } : { isolated: true }),
      ...(c.account ? { account: c.account } : {}) });
    const end = await waitOp(op.id);
    if (!end || end.state !== 'done') { SETUP.busy = false; button.disabled = false; return; }
    toast('Made ' + plan.name + ' — a try');
    if (SETUP.d) SETUP.d.close();
    state.tr = null;
    location.hash = '#/sandbox/' + plan.name;
    await startWithBootView(plan.name);
  } catch (e) {
    SETUP.busy = false;
    SETUP.error = e.message || String(e);
    pageFailure('Quick try: ' + SETUP.error, { key: 'quick-try' });
    paintSetup();
  }
}

// ── the page ─────────────────────────────────────────────────────────────────

/// Redraw what the search, the pills, the view or the choice changed — in place, so the search box keeps its focus.
function paint(opts) {
  const root = document.querySelector('[data-qt]');
  if (!root) { rerender(); return; }
  const tr = state.tr;
  const results = root.querySelector('[data-try-results]');
  results.className = 'qt-results ' + tr.view;
  results.replaceChildren(...resultsNodes());
  root.querySelector('[data-try-count]').textContent = countText();
  for (const b of root.querySelectorAll('[data-try-pill]')) b.setAttribute('aria-pressed', String(tr.f.has(b.dataset.tryPill)));
  for (const b of root.querySelectorAll('[data-try-view]')) b.setAttribute('aria-pressed', String(tr.view === b.dataset.tryView));
  const search = root.querySelector('[data-try-search]');
  if (opts.keepSearch === false) search.value = tr.q;
  root.querySelector('[data-try-detail]').replaceChildren(...detailNodes());
  root.dataset.detail = tr.detail ? '1' : '';
  if (opts.focusItem) { const s = results.querySelector('[aria-selected="true"]'); if (s) { s.focus(); s.scrollIntoView({ block: 'nearest' }); } }
  if (current()) root.dataset.try = current().id;
}

function onKey(ev) {
  const tr = state.tr;
  const t = ev.target;
  const inSearch = t.matches && t.matches('[data-try-search]');
  const inField = !inSearch && t.closest && t.closest('input, textarea, select, [contenteditable]');
  if (ev.key === '/' && !inSearch && !inField) {
    ev.preventDefault();
    const s = document.querySelector('[data-try-search]'); if (s) s.focus();
    return;
  }
  if ((ev.key === 'ArrowDown' || ev.key === 'ArrowUp') && !inField) {
    const list = hits(); if (!list.length) return;
    ev.preventDefault();
    const i = list.findIndex((a) => a.id === tr.agent);
    const next = list[(i + (ev.key === 'ArrowDown' ? 1 : list.length - 1)) % list.length];
    select(next.id, { focusItem: !inSearch });
    return;
  }
  // Enter = Try (the setup opens; Start is there).
  if (ev.key === 'Enter' && !inField && (inSearch || (t.closest && t.closest('[data-try-results]')))) {
    const s = document.querySelector('[data-try-open]');
    if (s && !s.disabled) { ev.preventDefault(); s.click(); }
  }
}

function tryNode() {
  const tr = state.tr;
  const close = btn('Close', () => wizardCloseRequest(), { title: 'Close (Esc)', icon: 'x' });
  close.classList.add('qt-close');
  close.dataset.wmClose = '';
  close.append(h('span', { class: 'qt-kbd', 'aria-hidden': 'true' }, 'Esc'));
  const head = h('header', { class: 'qt-mhead' },
    h('div', null, h('h1', { id: 'wm-title' }, 'Quick try'),
      h('p', { class: 'sub' }, 'Pick an agent and try it in a fresh sandbox: its own folder, the network locked to its model, your key never inside. Nothing is prepared until you press Start.')),
    close);
  if (!tr.catalog.agents.length && !tr.catalog.coming.length) {
    return h('div', { class: 'wizard try qt-page' }, head, callout('info', { body: 'No agent this Dozer can try.' }));
  }
  const root = h('div', { class: 'qt', 'data-qt': '', 'data-detail': tr.detail ? '1' : '' },
    leftPane(),
    h('section', { class: 'qt-right', 'aria-live': 'polite', 'aria-label': 'The chosen agent', 'data-try-detail': '' }, ...detailNodes()));
  if (current()) root.dataset.try = current().id;
  root.addEventListener('keydown', onKey);
  return h('div', { class: 'wizard try qt-page' }, head, root);
}
