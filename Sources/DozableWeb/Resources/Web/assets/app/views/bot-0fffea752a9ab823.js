// views/bot — One Agent / Bot (#/bots/NAME, mockups L3 and L2) and a new one (#/bots/~new). The header says who it is, how it
// runs and is reached, and its key — "held by Dozable · fp …", never a token. "Across workspaces" (the default): each
// workspace it manages or works in, whether it drives there, a link to its screen there; its rooms; what it said last,
// everywhere (read from chat only while this browser may). The edit tabs (components/bot-form.js) each save through ONE
// `bot-set`; Roles & ceiling shows the ceiling read only ("comes with permissions"). A retired bot, and every screen in
// another computer's browser, is read only — the buttons that change a bot are this Mac's own browser's (`mac-only`).
// Retire, a new token and adopting a participant are confirmed with a box to tick; a bot elsewhere gets its token only in
// a terminal (the command to copy).
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { api } from '../core/api-496fd9f39af2a514.js';
import { full, when } from '../core/format-b2e68384da8d2f36.js';
import { actOrThrow, waitForOp } from '../core/operations-c13d53e862eba3c7.js';
import { agentHash, botHash, roomHash, workspaceHash } from '../core/routes-0babfc190b1519e4.js';
import { isRemote } from '../core/session-ac3b294ded6521bf.js';
import { state } from '../core/state-f551ebce9066b2c8.js';
import { loadBot, loadBots, loadWorkspaces } from '../core/workspaces-c6a8f6fb9b6ba308.js';
import { callout } from '../components/callout-a906e34ef11cba9d.js';
import { cmdLine } from '../components/cmd-line-94674713f629d59c.js';
import { dialog } from '../components/dialog-178fb8a3742913d2.js';
import { moreMenu } from '../components/menus-2bfb74f31fa5969c.js';
import { toast } from '../components/notices-4785c4558bdd1082.js';
import { botChangeRefusal, botForm, elsewhereCommand, ISOLATION_WORDS, REACHED_WORDS, SECTIONS } from '../components/bot-form-6e8618ca53f1c710.js';
import { chatRooms, includeInRoom } from '../components/bot-invite-8c84f6eb7836e65c.js';
import { isolationChip } from '../components/iso-chip-620bfae2db3e5c80.js';
import { workspacePill } from '../components/ws-marks-d5ea1fd9ab813391.js';
import { programName } from '../components/ws-panel-af55abf0fe154f14.js';
import { openNewWorkspace } from './new-workspace-7a002d0ac929030c.js';

/// The key, as a person reads it: who keeps it and its fingerprint shortened (3f9a…c2) — the whole one in `title`.
export function keyWords(keeper, fp) {
  const short = fp ? (fp.length > 6 ? fp.slice(0, 4) + '…' + fp.slice(-2) : fp) : null;
  if (keeper === 'dozable') return 'held by Dozable' + (short ? ' · fp ' + short : '');
  if (keeper === 'elsewhere') return 'held elsewhere' + (short ? ' · fp ' + short : '');
  return 'none (retired)';
}
/// Its avatar: what it set (a short text or an emoji), else its initial.
export function botAvatar(b, cls) {
  const a = b.avatar || (b.name || '?').charAt(0).toUpperCase();
  return h('span', { class: 'bot-avatar' + (cls ? ' ' + cls : ''), 'aria-hidden': 'true' }, [...a].slice(0, 2).join(''));
}
/// The isolation chip ("acts as you" beside an unfenced one).
export function isolationChips(iso) {
  const chip = isolationChip(ISOLATION_WORDS[iso] ? (iso === 'unfenced' ? 'unfenced' : ISOLATION_WORDS[iso]) : iso, iso);
  chip.setAttribute('data-iso', iso);                                  // the bot's isolation as recorded
  return [chip,
    iso === 'unfenced' ? h('span', { class: 'ws-chip acts-as-you', title: 'Unfenced on this Mac: it acts as you' }, icon('triangle-alert'), 'acts as you') : null];
}

// ── the changes (each one action, this Mac's own browser only) ─────────────────────────────────────────────────────
/// A change confirmed with a box to tick; the dialog stays open with the daemon's refusal (e.g. "release it first").
function confirmBot(title, text, check, body, submit, opts = {}) {
  return dialog(title, text, opts.fields || [], submit, async (v) => {
    const extra = opts.extra ? opts.extra(v) : {};
    const op = await actOrThrow({ ...body, ...extra, confirm: body.name });
    const end = await waitForOp(op, 120);
    if (!end || end.state !== 'done') throw new Error(end ? end.text : 'It did not answer in time — see Operations.');
    state.botLast = { name: body.name, text: end.text };
    toast(end.text);
    if (opts.after) opts.after(end);
  }, { danger: !!opts.danger, confirmCheck: check, icon: opts.icon || 'triangle-alert' });
}
export function retireDialog(name) {
  confirmBot('Retire ' + name, 'It leaves chat and its token is refused. Its old messages keep its name, and the name is never used again. A bot in a workspace is released from it first.',
    'Yes, retire ' + name, { action: 'bot-retire', name }, 'Retire', { danger: true, icon: 'ban' });
}
export function tokenDialog(b) {
  if (b.isolation === 'elsewhere' || b.keeper === 'elsewhere') {
    dialog('A new token for ' + b.name, 'A bot elsewhere gets its token in a terminal on this Mac — it is shown once there, never in a browser.',
      [{ name: 'cmd', type: 'custom', el: cmdLine('doz bot token ' + b.name + ' --new --to-file ~/' + b.name + '.token'), get: () => null }], 'Close', async () => null, { icon: 'x' });
    return;
  }
  confirmBot('A new token for ' + b.name, 'The old one is refused from now on; a running ' + b.name + ' stops working until started again. The new one stays in your login keychain — nothing is shown.',
    'Yes, replace ' + b.name + '’s token', { action: 'bot-token', name: b.name }, 'Replace', { icon: 'key-round' });
}
/// Make a participant in chat an Agent / Bot (Q9's words: its token is replaced).
export function adoptDialog(name) {
  const agents = [['claude-code', 'Claude Code'], ['codex', 'Codex'], ['pi', 'pi']];
  confirmBot('Make ' + name + ' an Agent / Bot',
    name + ' becomes a bot. Its token is replaced: Dozable never had the old one. An agent still using the old token stops working the moment this runs.',
    'Yes, make ' + name + ' a bot and replace its token', { action: 'bot-adopt', name }, 'Make it a bot', {
      icon: 'bot',
      fields: [{ name: 'agent', label: 'Its agent program', type: 'select', options: agents, value: 'claude-code' },
        { name: 'isolation', label: 'Where it runs', type: 'select', options: [['fenced', 'fenced on this Mac'], ['vm', 'micro VM'], ['unfenced', 'unfenced on this Mac — acts as you']], value: 'fenced' },
        { name: 'elsewhere', type: 'custom', get: () => null,
          el: h('p', { class: 'muted bf-elsewhere-note' }, 'Elsewhere (another machine with its own token) is done in a terminal on this Mac: ',
            cmdLine('doz bot adopt ' + name + ' --agent codex --isolation elsewhere --to-file ~/' + name + '.token')) }],
      extra: (v) => ({ agent: v.agent, isolation: v.isolation }),
      after: () => { location.hash = botHash(name); },
    });
}
/// New workspace with this bot: the wizard with it chosen as the manager (#/new-workspace?bot=NAME).
export function newWorkspaceDialog(name) { openNewWorkspace(name); }
/// Duplicate: the new bot's form, filled from this one (its name empty).
export async function duplicateBot(name) {
  try { state.botDraft = await loadBot(name, 0); } catch (_) { state.botDraft = null; }
  location.hash = '#/bots/~new';
}

/// A bot's ⋯: Open, Edit, Duplicate, a new workspace with it, Include in a room…, Pause it everywhere (later), a new token,
/// Retire. Another computer: Open and Include only.
export function botMenuItems(b) {
  const why = botChangeRefusal(), retired = !!b.retiredAt;
  const items = [{ label: 'Open', icon: 'monitor', onSelect: () => { location.hash = botHash(b.name); } }];
  if (!why && !retired) {
    items.push({ label: 'Edit', icon: 'pencil', onSelect: () => { location.hash = botHash(b.name, 'identity'); } });
    items.push({ label: 'Duplicate', icon: 'copy', desc: 'A new Agent / Bot like it (e.g. with another model)', onSelect: () => duplicateBot(b.name) });
    items.push({ label: 'New workspace with this bot', icon: 'folder-plus', desc: 'As its manager', onSelect: () => newWorkspaceDialog(b.name) });
  }
  if (!retired) items.push({ label: 'Include in a room…', icon: 'users', desc: 'As a voice: no grants, no token step', onSelect: () => includeInRoom(b.name) });
  if (!why && !retired) {
    items.push({ label: 'Pause it everywhere', icon: 'pause', disabled: true, why: 'Comes later — for now: doz workspace stop W for each workspace it manages' });
    items.push({ label: 'New token…', icon: 'key-round', desc: 'The old one is refused at once', onSelect: () => tokenDialog(b) });
    items.push({ sep: true });
    items.push({ label: 'Retire…', icon: 'ban', danger: true, onSelect: () => retireDialog(b.name) });
  }
  return items;
}

// ── the screen ───────────────────────────────────────────────────────────────────────────────────────────────────
export async function viewBot() {
  const name = state.param;
  const key = name === '~new' ? '~new' : name + '/' + (state.botTab || '');
  // Unsaved changes on the form shown: a live refresh leaves the page as it is.
  if (state.botForm && state.botForm.dirty && state.botForm.key === key && $('view').querySelector('[data-bot-form]')) return null;
  if (name === '~new') return newBot();
  const [b, ws, accounts] = await Promise.all([loadBot(name, 0), loadWorkspaces(1000).catch(() => null), accountNames()]);
  if (state.botLast && state.botLast.name !== name) state.botLast = null;
  const tab = state.botTab;
  const remote = botChangeRefusal(), retired = !!b.retiredAt, readOnly = !!remote || retired;
  const head = h('div', { class: 'head bot-head' },
    botAvatar(b, 'is-lg'),
    h('h1', null, b.name),
    h('div', { class: 'bot-chips' },
      h('span', { class: 'ws-chip' }, icon('bot'), programName(b.agent) + (b.model ? ' · ' + b.model : '')),
      ...isolationChips(b.isolation),
      h('span', { class: 'ws-chip', title: 'How the chat server reaches it' }, REACHED_WORDS[b.deliver] || b.deliver)),
    h('div', { class: 'head-acts' }, moreMenu('More for ' + b.name, botMenuItems(b)).el));
  const keyLine = h('p', { class: 'bot-key', 'data-bot-key': b.keeper, 'data-bot-fp': b.fingerprint || '' },
    icon('key-round'), h('span', { title: b.fingerprint ? 'fingerprint ' + b.fingerprint + ' (12 hex of its SHA-256 — never the token)' : null }, keyWords(b.keeper, b.fingerprint)),
    b.keeper === 'dozable' ? h('span', { class: 'muted' }, ' — in your login keychain, never shown') : null);
  const tabs = h('nav', { class: 'ws-tabs bot-tabs', 'aria-label': b.name }, ...[[null, 'Across workspaces'], ...SECTIONS, ['roles', 'Roles & ceiling']].map(([t, label]) =>
    h('a', { href: botHash(b.name, t), class: 'ws-tab bot-tab' + ((tab || null) === t ? ' is-on' : ''), 'aria-current': (tab || null) === t ? 'page' : null, 'data-bot-tab': t || 'across' }, label)));
  let body;
  if (!tab) body = await across(b, ws);
  else if (tab === 'roles') body = roles(b);
  else body = editTab(b, tab, accounts, readOnly);
  return h('div', { class: 'bot-page', 'data-bot-page': b.name },
    head, keyLine,
    retired ? callout('info', { banner: true, attrs: { 'data-bot-retired': '' }, title: 'Retired ' + when(b.retiredAt),
      body: 'It left chat and its token is refused; its old messages keep its name, and the name is never used again.' }) : null,
    remote && !retired ? callout('info', { compact: true, body: 'Read only in this browser: ' + remote.toLowerCase() + ' — or with doz bot … in a terminal on the Mac.' }) : null,
    state.botLast && state.botLast.name === b.name ? callout('ok', { compact: true, attrs: { 'data-bot-last': '' }, body: state.botLast.text, dismiss: () => { state.botLast = null; } }) : null,
    tabs, body);
}

async function accountNames() {
  try { const a = await api('accounts'); return (a.accounts || []).map((x) => x.name); } catch (_) { return []; }
}

function editTab(b, tab, accounts, readOnly) {
  const f = botForm({ bot: b, tab, accounts, readOnly });
  const acts = readOnly ? null : h('div', { class: 'bot-save' },
    h('button', { type: 'button', class: 'btn quiet', on: { click: () => { state.botForm = null; location.hash = botHash(b.name); } } }, 'Cancel'),
    h('button', { type: 'button', class: 'btn primary', 'data-bot-save': '', on: { click: async (ev) => {
      const button = ev.currentTarget;
      button.disabled = true;
      const end = await f.save();
      button.disabled = false;
      if (end && end.state === 'done') { state.botLast = { name: b.name, text: end.text }; toast(end.text); }
    } } }, icon('check'), 'Save'));
  return h('div', { class: 'bot-edit' }, f.el, acts);
}

/// Roles & ceiling, read only: its role in each workspace (the workspace gives it), and its ceiling — each cap, set in a
/// terminal (doz bot ceiling). Enforced where an agent reaches Dozable: the run journal and the work description (dozchat).
function roles(b) {
  const held = Object.entries(b.roles || {}).sort((x, y) => x[0].localeCompare(y[0]));
  const caps = Object.entries(b.ceilingAnswers || {}).sort((x, y) => x[0].localeCompare(y[0]));
  const iso = b.ceiling === 'fenced' || b.ceiling === 'vm';
  return h('div', { class: 'bot-roles', 'data-bot-section': 'roles' },
    h('h2', null, 'Its roles'),
    held.length ? h('ul', { class: 'bot-role-list' }, ...held.map(([w, r]) => h('li', { 'data-bot-role': w },
      h('a', { href: workspaceHash(w) }, w), ': ', h('b', null, r), h('span', { class: 'muted' }, ' (from the workspace)'))))
      : h('p', { class: 'muted' }, 'Not an agent of any workspace yet. In a room it joins as a voice: it reads and speaks there, with no grants.'),
    h('h2', null, 'Its ceiling'),
    caps.length || iso ? h('ul', { class: 'bot-ceiling', 'data-bot-ceiling': caps.map(([p]) => p).join(' ') },
      ...caps.map(([p, a]) => h('li', { 'data-cap': p }, h('code', null, p), ' — ', h('b', null, a))),
      iso ? h('li', { 'data-cap': 'isolation.unfenced' }, h('code', null, 'isolation.unfenced'), ' — ', h('b', null, 'never'),
        h('span', { class: 'muted' }, ' (its isolation ceiling: ' + (ISOLATION_WORDS[b.ceiling] || b.ceiling) + ')')) : null)
      : h('p', null, 'None set: no cap.'),
    h('p', { class: 'muted' }, 'The most it may ever get, wherever it works — read only here; set in a terminal: ',
      cmdLine('doz bot ceiling ' + b.name + ' PERM=never')),
    h('p', { class: 'muted' }, 'Enforced where an agent reaches Dozable: the run journal and the work description, through dozchat.'));
}

/// Across workspaces: where it is, its rooms, what it said last.
async function across(b, ws) {
  const list = ws ? ws.workspaces : [];
  const names = [...new Set([...b.manages, ...b.workspaces, ...(b.worksIn ? [b.worksIn] : [])])];
  const rows = names.map((w) => {
    const row = list.find((x) => x.name === w);
    const manages = b.manages.includes(w), works = b.worksIn === w;
    const drives = manages && b.running === w;
    return h('tr', { 'data-bot-ws': w },
      h('td', null, h('a', { href: workspaceHash(w) }, w)),
      h('td', null, row ? workspacePill(row.state, row.words) : h('span', { class: 'muted' }, '—')),
      h('td', null, manages ? 'manager' : works ? 'worker' : 'agent'),
      h('td', null, drives ? 'yes (it runs)' : manages ? 'not running' : h('span', { class: 'muted' }, 'no')),
      h('td', null, h('a', { href: agentHash(w, b.name), class: 'btn sm quiet' }, 'Its screen there'), ' ',
        row && row.room ? h('a', { href: roomHash(w), class: 'btn sm quiet' }, icon('message-square'), 'Open room') : null));
  });
  const where = h('div', { class: 'panel' }, rows.length ? h('table', null,
    h('thead', null, h('tr', null, ...['Workspace', 'State', 'Its role', 'Drives there', ''].map((x) => h('th', null, x)))), h('tbody', null, ...rows))
    : h('div', { class: 'empty' }, 'Not in any workspace yet.'));
  const chat = await chatPart(b);
  return h('div', { class: 'bot-across', 'data-bot-section': 'across' },
    h('h2', null, 'Across workspaces'), where,
    !b.retiredAt && !b.manages.length ? h('p', { class: 'muted' }, 'Make it a workspace’s manager in a terminal: ', cmdLine('doz workspace new NAME --prompt-file BRIEF.md --manager ' + b.name)) : null,
    chat);
}

/// Its rooms and what it said last in each (≤ 12) — only while the chat server runs and this browser may read it.
async function chatPart(b) {
  const s = await chatRooms();
  if (!s) return h('div', { class: 'bot-chat' }, h('h2', null, 'Its rooms'), h('p', { class: 'muted', 'data-bot-chat-off': '' }, isRemote()
    ? 'Chat is shown only on this Mac (or as serve.chat allows).' : 'Chat is off — doz chat on to see its rooms.'));
  const mine = Object.keys(s.rooms || {}).filter((r) => (s.rooms[r] || []).includes(b.name)).sort();
  const last = await Promise.all(mine.slice(0, 12).map(async (r) => {
    try {
      const ms = await api('chat/rooms/' + r + '/messages?limit=20');
      const m = (Array.isArray(ms) ? ms : []).filter((x) => x.from === b.name && !x.deleted && x.kind !== 'private').pop();
      return m ? { room: r, at: +m.at ? new Date(m.at * 1000).toISOString() : null, text: String(m.content || '').replace(/\s+/g, ' ').trim() } : null;
    } catch (_) { return null; }
  }));
  const said = last.filter(Boolean).sort((a, c) => String(c.at).localeCompare(String(a.at)));
  return h('div', { class: 'bot-chat' },
    h('h2', null, 'Its rooms'),
    mine.length ? h('p', { class: 'bot-rooms', 'data-bot-rooms': mine.join(' ') }, ...mine.map((r, i) => [i ? ' · ' : '', h('a', { href: '#/chat/' + r }, '#' + r)]).flat())
      : h('p', { class: 'muted' }, 'In no room.'),
    h('h2', null, 'What it said last, everywhere'),
    said.length ? h('ul', { class: 'bot-said' }, ...said.map((x) => h('li', { 'data-bot-said': x.room },
      h('span', { class: 'muted', title: x.at ? full(x.at) : null }, x.at ? when(x.at) : ''), ' ', h('b', null, '#' + x.room + ': '), x.text.slice(0, 200))))
      : h('p', { class: 'muted' }, 'Nothing lately.'));
}

/// #/bots/~new — the same sections, empty (or a duplicate's, its name empty); fenced and poll by default.
async function newBot() {
  const remote = botChangeRefusal();
  const accounts = await accountNames();
  const draft = state.botDraft;
  state.botDraft = null;
  const seed = draft ? { ...draft, name: '', instructions: draft.instructions || '' } : null;
  const f = botForm({ bot: null, tab: null, accounts, readOnly: !!remote, seed });
  const make = h('button', { type: 'button', class: 'btn primary', disabled: remote ? true : null, title: remote || null, 'data-bot-make': '',
    on: { click: async (ev) => {
      const button = ev.currentTarget;
      button.disabled = true;
      const end = await f.save();
      button.disabled = false;
      if (end && end.state === 'done') {
        state.botLast = { name: f.values.name.trim(), text: end.text };
        toast(end.text);
        try { await loadBots(0); } catch (_) { /* the list is read again on the roster */ }
        location.hash = botHash(f.values.name.trim());
      }
    } } }, icon('plus'), 'Make the Agent / Bot');
  return h('div', { class: 'bot-page bot-new', 'data-bot-page': '~new' },
    h('div', { class: 'head' }, h('h1', null, draft ? 'A new Agent / Bot like ' + draft.name : 'A new Agent / Bot')),
    h('p', { class: 'sub' }, 'Defined once — its name in every room, its agent program, how it runs and is reached, its instructions — then played as a manager or a worker in workspaces.'),
    remote ? callout('info', { compact: true, body: [remote + ' — in a terminal on the Mac: ', cmdLine('doz bot new NAME --agent claude-code')] }) : null,
    callout('info', { compact: true, title: 'A bot on another machine?', body: ['It gets its token once, in a terminal on this Mac — never in a browser: ', cmdLine(elsewhereCommand())] }),
    f.el,
    h('div', { class: 'bot-save' }, h('a', { href: '#/bots', class: 'btn quiet' }, 'Cancel'), make));
}

