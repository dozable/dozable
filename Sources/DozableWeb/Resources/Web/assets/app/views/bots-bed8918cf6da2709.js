// views/bots — Agents / Bots (#/bots, mockup L1): the roster of the agents you keep — each defined once (`doz bot ls`): what it
// is, how it runs ("acts as you" when unfenced), how the chat server reaches it, what it manages or works in, who keeps its
// key (never a token) and its status. "+ New agent / bot" opens #/bots/~new; "Show retired" reads the retired ones
// (GET /bots?retired=1). Each row's ⋯ (views/bot.js botMenuItems); "Make a chat participant a bot…" adopts one. Every change
// is this Mac's own browser's: another computer sees the roster read only (Open and Include in a room… only).
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { when } from '../core/format-b2e68384da8d2f36.js';
import { refresh } from '../core/router-9bb5e215e0ec1e32.js';
import { agentHash, botHash, workspaceHash } from '../core/routes-c03e6aed84ec9eb3.js';
import { state } from '../core/state-1036883eb74b9520.js';
import { loadBots, loadRetiredBots, loadWorkspaces } from '../core/workspaces-89bbcc3668964701.js';
import { panel, table } from '../components/blocks-6b2d43608253a84f.js';
import { botChangeRefusal, REACHED_WORDS } from '../components/bot-form-c673ee01e1bcb134.js';
import { chatRooms } from '../components/bot-invite-9f3b8317e67e2957.js';
import { callout } from '../components/callout-a906e34ef11cba9d.js';
import { cmdLine } from '../components/cmd-line-4bb8898d42f31797.js';
import { dialog } from '../components/dialog-3979a75f824be091.js';
import { moreMenu } from '../components/menus-2bfb74f31fa5969c.js';
import { toast } from '../components/notices-e80cf681d1c67f6c.js';
import { programName } from '../components/ws-panel-d909bfe679786180.js';
import { adoptDialog, botAvatar, botMenuItems, isolationChips } from './bot-89b03e83ac6f558b.js';

const KEY = { dozable: 'held', elsewhere: 'elsewhere', none: 'none' };

export async function viewBots() {
  const retired = !!state.botsRetired;
  const [b] = await Promise.all([retired ? loadRetiredBots(0) : loadBots(0), loadWorkspaces(1000).catch(() => null)]);
  const remote = botChangeRefusal();
  const rows = b.bots.map((x) => {
    const roles = [];
    for (const w of x.manages) roles.push(h('span', { class: 'bot-role' }, 'manages ', h('a', { href: workspaceHash(w) }, w), x.running === w ? ' (running)' : ''));
    if (x.worksIn) roles.push(h('span', { class: 'bot-role' }, 'works in ', h('a', { href: workspaceHash(x.worksIn) }, x.worksIn), ' · ',
      h('a', { href: agentHash(x.worksIn, x.name) }, 'its screen')));
    const status = x.retiredAt ? 'retired ' + when(x.retiredAt) : x.running ? 'running in ' + x.running : x.worksIn ? 'working in ' + x.worksIn : x.inChat ? 'in chat' : 'not in chat yet';
    return h('tr', { 'data-bot': x.name },
      h('td', { class: 'bot-who' }, botAvatar(x), h('a', { href: botHash(x.name) }, h('b', null, x.name))),
      h('td', null, programName(x.agent) + (x.model ? ' · ' + x.model : '')),
      h('td', { class: 'bot-runs' }, ...isolationChips(x.isolation)),
      h('td', null, REACHED_WORDS[x.deliver] || x.deliver),
      h('td', null, roles.length ? roles.reduce((a, el, i) => (i ? a.push(h('br'), el) : a.push(el), a), []) : h('span', { class: 'muted' }, '—')),
      h('td', { 'data-bot-keeper': x.keeper || '' }, x.keeper ? KEY[x.keeper] || x.keeper : h('span', { class: 'muted' }, '—')),
      h('td', { class: 'bot-status' + (x.running ? ' is-running' : '') }, status),
      h('td', { class: 'bot-acts' }, h('a', { href: botHash(x.name), class: 'btn sm quiet' }, 'Open'), moreMenu('More for ' + x.name, botMenuItems(x), { small: true }).el));
  });
  const showRetired = h('label', { class: 'field check bot-show-retired' },
    h('input', { type: 'checkbox', 'data-bots-retired': '', checked: retired || null,
      on: { change: (ev) => { state.botsRetired = ev.target.checked; refresh(false); } } }),
    h('span', null, 'Show retired'));
  return h('div', { class: 'bots-page', 'data-bots-page': retired ? 'retired' : 'active' },
    h('div', { class: 'head' }, h('h1', null, 'Agents / Bots'),
      h('div', { class: 'head-acts' },
        remote ? null : h('button', { type: 'button', class: 'btn quiet', 'data-bots-adopt': '', on: { click: adoptChooser } }, icon('bot'), 'Make a chat participant a bot…'),
        h('a', { href: '#/bots/~new', class: 'btn primary' + (remote ? ' is-disabled' : ''), 'aria-disabled': remote ? 'true' : null, title: remote || null,
          'data-bots-new': '', on: remote ? { click: (ev) => ev.preventDefault() } : null }, icon('plus'), 'New agent / bot'))),
    h('p', { class: 'sub' }, 'The agents you keep: each is defined once — its agent program, how it runs and how the chat server reaches it — and plays a role in workspaces (a manager, a worker), or joins a room as a voice.'),
    remote ? callout('info', { compact: true, body: ['Read only in this browser: ' + remote.toLowerCase() + ' — or in a terminal on the Mac: ', cmdLine('doz bot new NAME --agent claude-code')] }) : null,
    showRetired,
    panel(table(['Agent / Bot', 'Agent program · model', 'Runs', 'Reached by', 'Managing / working in', 'Key', 'Status', ''], rows),
      retired ? 'No retired Agents / Bots.' : 'No Agents / Bots yet — “New agent / bot” makes one.'),
    h('div', { class: 'bot-notes' },
      callout('info', { compact: true, title: 'One identity, many workspaces', body: 'Each workspace runs its own session of the bot, with its own conversation; the name, avatar and chat identity are shared.' }),
      callout('info', { compact: true, title: 'Retire, don’t delete', body: 'A retired bot’s name stays on its messages and is never used again; its token is refused.' }),
      // The command goes in the body (where .cmd-line wraps), never in `actions`: that column is sized to its content,
      // and a long unbroken command there took the whole width and left the text one letter wide.
      callout('info', { compact: true, title: 'Its key is never shown', body: ['Dozable keeps a bot’s token in your login keychain and shows its fingerprint only. A bot on another machine gets its token in a terminal on this Mac:',
        cmdLine('doz bot new far --agent codex --isolation elsewhere --to-file ~/far.token')] })));
}

/// "Make a chat participant a bot…": the participants in chat that are not bots (nor people), then the adopt dialog.
async function adoptChooser() {
  const [s, b] = await Promise.all([chatRooms(), loadBots(0).catch(() => null)]);
  if (!s) { toast('Chat is off — the participants are read from it (doz chat on)', true); return; }
  const bots = new Set((b ? b.bots : []).map((x) => x.name));
  const list = (s.participants || []).filter((p) => p.kind !== 'human' && !bots.has(p.name)).map((p) => p.name).sort();
  if (!list.length) { toast('Every participant in chat is a bot or a person already'); return; }
  dialog('Make a chat participant a bot', 'Which participant? It keeps its kind, rooms and history; its token is replaced.',
    [{ name: 'who', label: 'The participant', type: 'select', options: list }], 'Next', async (v) => { setTimeout(() => adoptDialog(v.who), 0); }, { icon: 'bot' });
}
