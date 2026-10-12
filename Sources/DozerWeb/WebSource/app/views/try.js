// views/try — Quick try (617, 616.03 mock c; the owner: "Quick try is in phase 1"): an agent and its key — everything
// else a safe default. The same decisions as `doz try`: the host's planner (`POST plan`, purpose try) names it
// try-AGENT, gives it a NEW EMPTY folder of its own (never one of yours), Locked + its own model, the agent's own base
// and the provider's default key; the "What you need" card comes from the recipe (`GET try`). Browsing prepares NOTHING
// (owner: no build per recipe looked at); Create makes it with the ordinary `create` action (trial), starts it (the image prepared then, its progress in the terminal area) and opens
// its session. A try's page then offers Sleep · Delete · Keep (`tryBar`, components/try-bar.js).
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { api } from '../core/api.js';
import { act, actOrThrow, prepRunning, waitOp } from '../core/operations.js';
import { secretEntryAllowed } from '../core/settings.js';
import { state } from '../core/state.js';
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { startWithBootView } from '../components/lifecycle.js';
import { renderModal, wizHead } from '../components/modal.js';
import { pageFailure, toast } from '../components/notices.js';
import { planCommand, reachList } from '../components/plan-view.js';
import { prepCard } from '../components/prep-card.js';

const AGENT_ID = /^[a-z0-9][a-z0-9-]{0,39}$/;

/// The modal's view (the router passes the agent of `#/try/AGENT`).
export async function viewTry() {
  const want = state.tryAgent && AGENT_ID.test(state.tryAgent) ? state.tryAgent : null;
  if (!state.tr || state.tr.asked !== want) {
    const catalog = await api('try');
    const first = catalog.agents.find((a) => a.id === want) || catalog.agents.find((a) => !a.card) || catalog.agents[0] || null;
    state.tr = { asked: want, catalog, agent: first ? first.id : null, pasting: '', error: '', creating: false, };
  }
  return tryNode();
}

function current() {
  const tr = state.tr;
  return tr && tr.catalog.agents.find((a) => a.id === tr.agent);
}

function rerender() { if (state.modal === 'try') renderModal(false); }

/// 594's preparations arrive over SSE: the card of the chosen agent's image is drawn in place.
export function renderTryPrep() {
  const box = document.querySelector('[data-try-prep]');
  const a = current();
  if (!box || !a) return;
  box.replaceChildren(...prepNodes(a));
}

function prepNodes(a) {
  const p = (state.preps || []).find((x) => x.image === a.plan.image.name);
  if (p && (prepRunning(p) || p.error)) return [prepCard(p)];
  if (a.plan.image.state === 'unprepared' && !(p && p.state === 'done')) {
    return [h('p', { class: 'muted' }, 'Its image is prepared the first time it starts (minutes; it needs the network) — the progress shows in its terminal area.')];
  }
  return [h('p', { class: 'muted', 'data-try-ready': '' }, (a.plan.image.title || a.plan.image.name) + ' — ready')];
}

function agentCards() {
  const tr = state.tr;
  const cards = tr.catalog.agents.map((a) => {
    const who = a.providerTitle || 'provider';
    const key = a.card ? 'needs ' + (/^(?:[AEIOU]|xAI)/.test(who) ? 'an ' : 'a ') + who + ' key' : a.plan.account && a.plan.account.name ? 'key: ' + a.plan.account.name : 'ready';
    // Its latest release (measured by the host) and, when it is not current, its standing with its maker.
    const b = h('button', { type: 'button', class: 'try-agent' + (a.id === tr.agent ? ' selected' : '') + (a.standing ? ' superseded' : ''),
      'data-try-agent': a.id, 'aria-pressed': String(a.id === tr.agent) },
      h('span', { class: 'try-agent-title' }, a.title),
      h('span', { class: 'try-agent-sub muted' }, a.publisher + (a.base ? ' · ' + a.base : '')),
      h('span', { class: 'try-agent-key' + (a.card ? ' needs' : '') }, key),
      a.latest ? h('span', { class: 'try-agent-latest muted', 'data-try-latest': a.id }, a.latest) : null,
      a.standing ? h('span', { class: 'try-agent-standing', 'data-try-standing': a.id }, a.standing) : null);
    b.addEventListener('click', () => { tr.agent = a.id; tr.error = ''; tr.pasting = ''; history.replaceState(null, '', '#/try/' + a.id); state.tryAgent = a.id; tr.asked = a.id; rerender(); });
    return b;
  });
  const coming = tr.catalog.coming.map((c) => h('div', { class: 'try-agent coming', 'aria-disabled': 'true', title: c.reason, 'data-try-coming': c.id },
    h('span', { class: 'try-agent-title' }, c.title),
    h('span', { class: 'try-agent-sub muted' }, c.publisher),
    h('span', { class: 'try-agent-key muted' }, 'coming — ' + c.reason)));
  return h('div', { class: 'try-agents', role: 'group', 'aria-label': 'Agent' }, ...cards, ...coming);
}

/// "What you need" — the recipe's card: paste a key here (where the setting allows it), or the command for the ways
/// that stay in a terminal (1Password, AWS, a program); a sign-in that cannot work in a sandbox is labelled, not offered.
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
            state.tr = null;                                  // read the list again: the key is there now
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
  return h('section', { class: 'try-need', 'data-try-need': '' },
    h('h3', null, c.title),
    ...rows,
    c.getKey ? h('p', { class: 'muted' }, c.getKey) : null,
    h('div', null, btn('Check again', () => { state.tr = null; rerender(); }, { small: true, quiet: true, icon: 'refresh-cw' })));
}

function defaultsFacts(a) {
  const p = a.plan;
  const lines = (kind) => p.reach.filter((r) => r.kind === kind).map((r) => r.text);
  const fact = (k, v) => [h('dt', null, k), h('dd', null, v)];
  return h('dl', { class: 'facts try-facts' },
    ...fact('Name', p.name),
    ...fact('Base', a.base || '—'),
    ...fact('Network', 'Locked — only its model (' + (lines('model')[0] || 'its model') + ')'),
    ...fact('Folder', lines('folder')[0] || '—'),
    ...fact('Your Mac', lines('bridge').join(' · ') || '—'));
}

function tryNode() {
  const tr = state.tr, a = current();
  const head = wizHead('Quick try', 'An agent and its key — everything else is a safe default: a new empty folder of its own, and it reaches only its model.', [], null);
  if (!a) {
    return h('div', { class: 'wizard try' }, head, h('div', { class: 'wiz-card' }, h('div', { class: 'w-body' }, callout('info', { body: 'No agent this Dozer can try.' }))));
  }
  const blocked = a.plan.problems.filter((p) => p.code !== 'key');
  const create = btn(a.card ? 'Add a key first' : 'Create and open', () => tryCreate(create), { primary: true, lg: true, icon: 'rocket' });
  create.dataset.tryCreate = '';
  create.disabled = !!a.card || blocked.length > 0 || tr.creating;
  const body = h('div', { class: 'w-body' },
    h('h2', null, 'Agent'), agentCards(),
    a.card ? whatYouNeed(a) : h('p', { class: 'try-key', 'data-try-key-ok': '' }, 'Key: ' + ((a.plan.account && (a.plan.account.name + (a.plan.account.sourceLabel ? ' — ' + a.plan.account.sourceLabel : ''))) || 'none needed')),
    h('div', { class: 'try-prep', 'data-try-prep': '' }, ...prepNodes(a)),
    h('h3', null, 'Everything else — the defaults'), defaultsFacts(a),
    h('h3', null, 'The same, in a terminal'), planCommand(a.plan),
    h('details', { class: 'disclosure' }, h('summary', null, icon('chevron-down'), 'What it can reach'), reachList(a.plan.reach)),
    ...blocked.map((p) => callout('bad', { compact: true, body: p.text + (p.fix ? ' — ' + p.fix : '') })),
    tr.error ? callout('bad', { compact: true, attrs: { 'data-try-error': '' }, body: tr.error }) : null);
  return h('div', { class: 'wizard try', 'data-try': a.id }, head,
    h('div', { class: 'wiz-card' }, body, h('div', { class: 'w-foot wiz-buttons' }, h('span', { class: 'wiz-gap' }), create)));
}

/// Create → the ordinary `create` action (a try: `trial`, its new folder), then the start with the boot view, which
/// opens its own session in a terminal on its page.
async function tryCreate(button) {
  const tr = state.tr, a = current();
  if (!a || tr.creating) return;
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

