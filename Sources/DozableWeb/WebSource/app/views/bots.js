// views/bots — Agents / Bots (#/bots): the roster — who each agent/bot is, defined once (`doz bot ls`). A list only: what
// changes a bot is the CLI's (`doz bot new|set|retire`).
import { h } from '../dom/h.js';
import { when } from '../core/format.js';
import { state } from '../core/state.js';
import { loadBots, loadWorkspaces } from '../core/workspaces.js';
import { panel, table } from '../components/blocks.js';
import { callout } from '../components/callout.js';
import { cmdLine } from '../components/cmd-line.js';

const ISOLATION = { vm: 'micro VM', fenced: 'fenced on this Mac', unfenced: 'unfenced on this Mac — acts as you', elsewhere: 'elsewhere' };
const REACHED = { inbox: 'inbox', poll: 'poll (dozchat)', webhook: 'webhook' };

export async function viewBots() {
  const [b] = await Promise.all([loadBots(0), loadWorkspaces(1000).catch(() => null)]);
  const roomOf = (w) => { const x = state.workspaces && state.workspaces.workspaces.find((y) => y.name === w); return x ? x.room : null; };
  const wsLink = (w) => { const r = roomOf(w); return r ? h('a', { href: '#/chat/' + r, title: 'Its room ' + r }, w) : h('span', null, w); };
  const rows = b.bots.map((x) => {
    const roles = [];
    for (const w of x.manages) roles.push(h('span', { class: 'bot-role' }, 'manages ', wsLink(w), x.running === w ? ' (running)' : ''));
    if (x.worksIn) roles.push(h('span', { class: 'bot-role' }, 'works in ', wsLink(x.worksIn)));
    return h('tr', { 'data-bot': x.name },
      h('td', null, h('b', null, x.name)),
      h('td', null, x.agent + (x.model ? ' · ' + x.model : '')),
      h('td', { class: x.isolation === 'unfenced' ? 'bot-unfenced' : null }, ISOLATION[x.isolation] || x.isolation),
      h('td', null, REACHED[x.deliver] || x.deliver),
      h('td', null, roles.length ? roles.reduce((a, el, i) => (i ? a.push(h('br'), el) : a.push(el), a), []) : h('span', { class: 'muted' }, '—')),
      h('td', null, x.inChat ? 'yes' : h('span', { class: 'muted' }, 'not yet')),
      h('td', null, x.retiredAt ? when(x.retiredAt) : h('span', { class: 'muted' }, '—')));
  });
  return h('div', { class: 'bots-page', 'data-bots-page': '' },
    h('div', { class: 'head' }, h('h1', null, 'Agents / Bots')),
    h('p', { class: 'sub' }, 'The agents you keep: each is defined once — its agent program, how it runs and how the chat server reaches it — and plays a role in workspaces (a manager, a worker).'),
    panel(table(['Name', 'Agent program', 'Isolation', 'Reached by', 'Manages / works in', 'In chat', 'Retired'], rows), 'No Agents / Bots yet.'),
    callout('info', { title: 'The command', body: ['A new one is made in a terminal on this Mac: ', cmdLine('doz bot new NAME --agent claude-code'),
      ' — ', h('code', null, 'doz bot ls'), ' lists them, ', h('code', null, 'doz bot retire NAME'), ' retires one (its name stays on its messages).'] }));
}
