// views/try — Quick try (617; the owner's redesign, mock 616 quick-try-v2): a FULL-PAGE modal over the whole app
// (#/try, #/try/AGENT; Esc or Close returns to where it was opened; the app behind is inert). Two panes: on the left a
// search box (`doz search`'s matching + fuzzy, core/agent-search.js), the filter pills (Ready · Open source · Current ·
// Headless · Through a gateway — AND), the count and the cards/list toggle (remembered), then the results, superseded
// last; on the right the chosen agent: its mark, version and age, standing, What you need, the plan and Start.
// Keyboard: / searches, ↑/↓ move through the results, Enter starts. Below 760 px the panes stack (a back control).
//
// The same decisions as `doz try`: the host's planner (`POST plan`, purpose try) names it try-AGENT, gives it a NEW
// EMPTY folder of its own, Locked + its own model, the agent's own base and the provider's default key; "What you
// need" comes from the recipe (`GET try`). Browsing prepares NOTHING (owner: no build per recipe looked at); Start
// makes it with the ordinary `create` action (trial), starts it (the image prepared then, its progress in the terminal
// area) and opens its session. A try's page then offers Sleep · Delete · Keep (`tryBar`, components/try-bar.js).
import { h } from '../dom/h.js';
import { icon, mark } from '../dom/icons.js';
import { api } from '../core/api.js';
import { rank, suggest } from '../core/agent-search.js';
import { actOrThrow, prepRunning, waitOp } from '../core/operations.js';
import { secretEntryAllowed } from '../core/settings.js';
import { state } from '../core/state.js';
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { startWithBootView } from '../components/lifecycle.js';
import { renderModal, wizardCloseRequest } from '../components/modal.js';
import { pageFailure, toast } from '../components/notices.js';
import { planCommand, reachList } from '../components/plan-view.js';
import { prepCard } from '../components/prep-card.js';

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
    return [h('span', null, 'Nothing else — its image is prepared when you press Start (minutes the first time; it needs the network); the progress shows in its terminal area.')];
  }
  return [h('span', { 'data-try-ready': '' }, 'Nothing else — its image (' + (a.plan.image.title || a.plan.image.name) + ') is ready.')];
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

// ── the right pane ───────────────────────────────────────────────────────────

/// "What you need" when a key is missing — the recipe's card: paste a key here (where the setting allows it), or the
/// command for the ways that stay in a terminal (1Password, AWS, a program); a sign-in that cannot work in a sandbox
/// is labelled, not offered.
function whatYouNeed(a) {
  const tr = state.tr, c = a.card;
  const rows = [];
  for (const o of c.options) {
    if (o.kind === 'paste') {
      if (secretEntryAllowed()) {
        const field = h('input', { type: 'password', autocomplete: 'off', spellcheck: 'false', 'data-try-key': '', placeholder: 'paste the key', 'aria-label': o.label });
        const save = btn('Save the key', async () => {
          const secret = field.value.trim();
          field.value = '';                                   // emptied before the request
          if (!secret) return;
          save.disabled = true;
          try {
            const p = a.provider;
            const kind = p === 'anthropic' ? 'api-key' : p === 'openai' ? 'openai-key' : 'key';
            await api('accounts', { method: 'POST', json: { name: p || a.id, kind, secret, ...(kind === 'key' ? { provider: p } : {}) } });
            toast('Key saved — ' + (a.providerTitle || p));
            tr.asked = '\u0000';                               // read the list again: the key is there now
            rerender();
          } catch (e) { tr.error = e.message || String(e); save.disabled = false; rerender(); }
        }, { small: true, icon: 'key-round' });
        rows.push(h('div', { class: 'try-option' }, h('div', null, h('strong', null, o.label), h('div', { class: 'muted' }, o.consequence)), h('div', { class: 'try-paste' }, field, save)));
      } else {
        rows.push(h('div', { class: 'try-option' }, h('strong', null, o.label), h('div', { class: 'muted' }, 'Pasting keys here is off (ui.allow_secret_entry) — in a terminal on this Mac:'),
          h('code', null, c.addCommand || 'doz account add NAME')));
      }
    } else if (o.kind === 'source') {
      rows.push(h('div', { class: 'try-option' }, h('strong', null, o.label), h('div', { class: 'muted' }, o.consequence + ' — set up in a terminal on this Mac:'),
        h('code', null, (c.addCommand || 'doz account add NAME') + ' --from op://VAULT/ITEM/FIELD'),
        h('div', { class: 'muted' }, 'or --from aws:arn:… or --from-command \'…\'; then press Check again.')));
    } else {
      rows.push(h('div', { class: 'try-option' }, h('strong', null, o.label), h('div', { class: 'muted' }, o.consequence)));
    }
  }
  for (const n of c.notOffered) rows.push(h('div', { class: 'try-option not-offered', 'data-try-not-offered': '' }, h('strong', null, 'Not offered here'), h('div', { class: 'muted' }, n)));
  return h('div', { class: 'try-need', 'data-try-need': '' },
    h('h4', null, c.title),
    ...rows,
    c.getKey ? h('p', { class: 'muted' }, c.getKey) : null,
    h('div', null, btn('Check again', () => { tr.asked = '\u0000'; rerender(); }, { small: true, quiet: true, icon: 'refresh-cw' })));
}

function planFacts(a) {
  const p = a.plan;
  const lines = (kind) => p.reach.filter((r) => r.kind === kind).map((r) => r.text);
  const fact = (k, v) => [h('dt', null, k), h('dd', null, v)];
  return h('dl', { class: 'qt-plan try-facts' },
    ...fact('Name', p.name),
    ...fact('Base', a.base || '—'),
    ...fact('Network', 'Locked — only its model (' + (lines('model')[0] || 'its model') + ')'),
    ...fact('Folder', lines('folder')[0] || '—'),
    ...fact('Your Mac', lines('bridge').join(' · ') || '—'));
}

function sect(title, ...body) { return h('div', { class: 'qt-sect' }, h('h3', null, title), ...body); }

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
    a.version ? h('span', { class: 'tag outline', 'data-try-latest': a.id }, a.version + (a.age ? ' · released ' + ago(a.age) : '')) : null,
    a.headless ? h('span', { class: 'tag outline' }, 'headless') : null,
    a.gateway ? h('span', { class: 'tag outline' }, 'through a gateway') : null);
  const by = a.supersededBy && state.tr.catalog.agents.find((x) => x.id === a.supersededBy);
  const standing = a.current === false
    ? callout('warn', { attrs: { 'data-try-standing': a.id }, title: by ? 'Superseded by ' + by.title : 'Not current with its maker',
      body: h('span', null, (a.standing || '').replace(/^Superseded by [^—]*—\s*/, '') + ' ', by ? h('button', { type: 'button', class: 'linkish', on: { click: () => select(by.id, { detail: true }) } }, 'Try ' + by.title + ' instead') : null) })
    : null;
  const blocked = a.plan.problems.filter((p) => p.code !== 'key');
  const need = a.card ? whatYouNeed(a)
    : h('ul', { class: 'qt-need' },
      h('li', { 'data-try-key-ok': '' }, h('span', { class: 'ok' }, icon('circle-check')),
        h('span', null, 'Key: ', h('strong', null, (a.plan.account && (a.plan.account.name + (a.plan.account.sourceLabel ? ' — ' + a.plan.account.sourceLabel : ''))) || 'none needed'),
          ' — the sandbox only ever sees a placeholder.')),
      h('li', null, h('span', { class: 'ok' }, icon('circle-check')), h('span', { class: 'try-prep', 'data-try-prep': '' }, ...prepNodes(a))));
  const start = btn(a.card ? 'Add a key first' : 'Start', () => tryCreate(start), { primary: true, lg: true, icon: 'rocket' });
  start.dataset.tryCreate = '';
  start.disabled = !!a.card || blocked.length > 0 || tr.creating;
  return [back, head, facts, standing,
    a.latest ? h('p', { class: 'muted qt-latest' }, a.latest) : null,
    sect('What you need', need),
    sect('The plan', planFacts(a)),
    sect('The same, in a terminal', planCommand(a.plan)),
    h('details', { class: 'disclosure' }, h('summary', null, icon('chevron-down'), 'What it can reach'), reachList(a.plan.reach)),
    ...blocked.map((p) => callout('bad', { compact: true, body: p.text + (p.fix ? ' — ' + p.fix : '') })),
    tr.error ? callout('bad', { compact: true, attrs: { 'data-try-error': '' }, body: tr.error }) : null,
    h('div', { class: 'qt-foot' }, h('span', { class: 'qt-gap' }),
      h('span', { class: 'qt-note' }, a.card ? 'Add a key first' : 'Enter'), start)].filter(Boolean);   // (replaceChildren writes a null as "null")
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
  if (ev.key === 'Enter' && !inField && (inSearch || (t.closest && t.closest('[data-try-results]')))) {
    const s = document.querySelector('[data-try-create]');
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

/// Start → the ordinary `create` action (a try: `trial`, its new folder), then the start with the boot view, which
/// opens its own session in a terminal on its page.
async function tryCreate(button) {
  const tr = state.tr, a = current();
  if (!a || a.kind !== 'agent' || tr.creating) return;
  tr.creating = true;
  button.disabled = true;
  const c = a.plan.create;
  try {
    const op = await actOrThrow({ action: 'create', sandbox: a.plan.name, image: c.image, trial: true,
      ...(c.network ? { network: c.network } : {}), ...(c.workspace ? { workspace: c.workspace } : { isolated: true }),
      ...(c.account ? { account: c.account } : {}) });
    const end = await waitOp(op.id);
    if (!end || end.state !== 'done') { tr.creating = false; button.disabled = false; return; }
    toast('Made ' + a.plan.name + ' — a try');
    state.tr = null;
    location.hash = '#/sandbox/' + a.plan.name;
    await startWithBootView(a.plan.name);
  } catch (e) {
    tr.creating = false;
    tr.error = e.message || String(e);
    pageFailure('Quick try: ' + tr.error, { key: 'quick-try' });
    rerender();
  }
}
