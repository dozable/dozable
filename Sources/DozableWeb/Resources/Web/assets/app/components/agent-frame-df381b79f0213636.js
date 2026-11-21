// components/agent-frame — An agent's screen (#/w/NAME/agent/AGENT): its sandbox's or its session's page as today, framed by
// its workspace — the breadcrumb "NAME › AGENT", its chips (program, isolation, "acts as you"), "Open the room beside", and
// in the Overview an "In this workspace" block (role, task, who started it and when, bot, isolation and control, rooms,
// the CLI's line). `state.frame` (the router sets it) is the frame; `frameOf` says whether a page is the framed one.
// A sandbox's or a session's own page (#/sandbox/NAME, #/mac/here/SESSION) of an agent in a workspace is NOT redirected:
// it carries `memberStrip` — "In NAME as AGENT — open it there" and "Take out…".
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { full, when } from '../core/format-b2e68384da8d2f36.js';
import { addWorkerHash, agentHash, agentsHash, canDoHash, workspaceHash } from '../core/routes-ce13c8979e42e1cc.js';
import { state } from '../core/state-dee60cc8f4c9cdbe.js';
import { loadWorkspace, loadWorkspaces } from '../core/workspaces-58675c2e3031a177.js';
import { cmdLine } from './cmd-line-d408fcba356d6a76.js';
import { isolationChip } from './iso-chip-61adb195eb227252.js';
import { moreMenu } from './menus-b8f822d6b7817c72.js';
import { addCommand, endWorkerItem, workerRefusal } from './worker-end-a2943c99cd2aa2b4.js';
import { takeOut } from './put-in-workspace-57f96427e22b95eb.js';
import { isolationWords, programName } from './ws-panel-a4c3eca88d42e336.js';

/// The frame of the page showing `place` (a sandbox's name, or a session on this Mac) — null when it is not framed.
export function frameOf(kind, place) {
  const f = state.frame;
  return f && f.kind === kind && f.place === place && f.row ? f : null;
}

/// What an agent runs: its bot's program (Agents / Bots), else nothing known.
function programOf(a) {
  const bot = a.bot && state.bots ? state.bots.bots.find((b) => b.name === a.bot) : null;
  return bot ? programName(bot.agent) : null;
}

/// The chips every view of an agent carries: program, isolation, "acts as you".
export function agentChips(a) {
  const iso = isolationWords(a), prog = programOf(a);
  return [
    prog ? h('span', { class: 'ws-chip', title: a.bot ? 'Agent / Bot ' + a.bot : null }, icon('bot'), prog) : null,
    isolationChip(iso),
    a.actsAsYou || (a.kind === 'mac' && a.isolation === 'unfenced')
      ? h('span', { class: 'ws-chip acts-as-you', title: 'Unfenced on this Mac: it acts as you' }, icon('triangle-alert'), 'acts as you') : null,
  ].filter(Boolean);
}

/// The frame's row above the page's own title: NAME › Agents › AGENT, the chips, "Open the room beside".
export function frameBar(f) {
  const a = f.row;
  return h('div', { class: 'agent-frame', 'data-agent-frame': f.workspace + '/' + f.agent },
    h('nav', { class: 'agent-crumb', 'aria-label': 'Where this agent is' },
      h('a', { href: workspaceHash(f.workspace), 'data-crumb-ws': f.workspace }, f.workspace),
      h('span', { class: 'agent-crumb-sep', 'aria-hidden': 'true' }, '›'),
      h('a', { href: agentsHash(f.workspace) }, 'Agents'),
      h('span', { class: 'agent-crumb-sep', 'aria-hidden': 'true' }, '›'),
      h('span', { class: 'agent-crumb-here', 'aria-current': 'page' }, f.agent)),
    h('span', { class: 'agent-frame-chips' }, h('span', { class: 'ws-chip' }, a.role), ...agentChips(a)),
    h('span', { class: 'ws-sp' }),
    h('a', { class: 'btn sm quiet', href: canDoHash(f.workspace, f.agent), 'data-can-do': f.agent, title: 'What ' + f.agent + ' can do: isolation, folders, network, secrets by name' },
      icon('shield'), 'Can do'),
    h('a', { class: 'btn sm quiet', href: workspaceHash(f.workspace), 'data-room-beside': f.workspace, title: 'The workspace’s room, with this agent among its people' },
      icon('message-square'), 'Open the room beside'),
    moreMenu('More for ' + f.agent, frameItems(f), { small: true, data: { agentFrameMore: f.agent } }).el);
}

/// The frame's ⋯: Add a worker (its page), and End… for a live worker (the `worker-end` action) — this Mac's own browser only.
function frameItems(f) {
  const a = f.row, why = workerRefusal();
  const items = [{ label: 'Add a worker…', icon: 'plus', desc: why ? why + ': ' + addCommand(f.workspace) : 'Another agent with one task, in ' + f.workspace,
    disabled: !!why, why, data: { 'frame-add-worker': f.workspace }, onSelect: () => { location.hash = addWorkerHash(f.workspace); } }];
  if (a.role === 'worker' && a.task && a.state !== 'ended') items.push(endWorkerItem(f.workspace, a, () => { location.hash = agentsHash(f.workspace); }));
  return items;
}

/// "In this workspace" — the Overview's block on a framed page.
export function frameBlock(f) {
  const a = f.row, d = f.detail;
  const rooms = d ? d.rooms.slice().sort((x, y) => (x.main ? -1 : y.main ? 1 : x.label.localeCompare(y.label))) : [];
  const fact = (k, v) => (v ? [h('dt', null, k), h('dd', null, v)] : []);
  return h('div', { class: 'agent-in-ws', 'data-agent-in-ws': f.workspace },
    h('div', { class: 'insp-lbl' }, 'In this workspace'),
    h('dl', { class: 'facts' },
      ...fact('Workspace', h('a', { href: workspaceHash(f.workspace) }, f.workspace)),
      ...fact('Role', a.role),
      ...fact('Task', a.task || (a.role === 'manager' ? 'runs the workspace' : 'adopted — no task of its own')),
      ...fact('Started by', h('span', { title: full(a.startedAt) }, (a.startedBy || 'you') + ' · ' + when(a.startedAt))),
      ...fact('Agent / Bot', a.bot || null),
      ...fact('Isolation', [isolationWords(a), a.control ? ' · ' + a.control : ''].join('')),
      ...fact('Rooms', rooms.length ? rooms.map((r) => '#' + (r.main ? r.room : r.label)).join(' · ') : 'none yet')),
    cmdLine('doz worker ls ' + f.workspace));
}

/// A sandbox's or a session's own page, of an agent in a workspace: "In NAME as AGENT — open it there" and "Take out…";
/// a loose one shows nothing (its ⋯ menu offers "Put in a workspace…"). Filled once the listing (and that workspace) are read — never on a timer.
/// `place`: as a person types it (`wsa`, `@mac/wsu`).
export function memberStrip(place) {
  const el = h('div', { class: 'agent-member', 'data-member-of': '', hidden: true });
  const fill = (l) => {
    if (!l) return null;
    const w = l.workspaces.find((x) => (x.places || []).includes(place));
    if (!w) {
      // A loose agent says nothing here (its ⋯ offers Put in a workspace…).
      el.dataset.memberOf = '';
      el.hidden = true;
      el.replaceChildren();
      return null;
    }
    el.hidden = false;
    const d = state.wsDetails.get(w.name);
    const a = d ? d.agents.find((x) => x.place === place) : null;
    el.dataset.memberOf = w.name;
    el.replaceChildren(icon('layers'),
      h('span', null, 'In ', h('a', { href: workspaceHash(w.name) }, w.name), a ? ' as ' + a.name : '', ' — '),
      h('a', { href: a ? agentHash(w.name, a.name) : workspaceHash(w.name), 'data-member-open': w.name }, 'open it there'),
      a ? h('button', { type: 'button', class: 'btn sm quiet', 'data-take-out': a.name, on: { click: () => takeOut(w.name, a) } }, icon('log-out'), 'Take out…') : null);
    return w.name;
  };
  // What was read last at once (nothing moves when the page is drawn again), then a read no older than 5 s.
  fill(state.workspaces);
  (async () => {
    let l = state.workspaces;
    try { l = await loadWorkspaces(5000); } catch (_) { /* the last read */ }
    const w = fill(l);
    if (w) { try { await loadWorkspace(w, 5000); fill(state.workspaces); } catch (_) { /* named without its agent */ } }
  })();
  return el;
}
