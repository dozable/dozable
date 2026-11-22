// views/ws-agents — A workspace's Agents tab (#/w/NAME/agents) and the card an agent's screen shows when it has no page
// (#/w/NAME/agent/AGENT: an agent elsewhere, a manager not started, a place gone). One table for every kind of agent —
// micro VM, fenced, unfenced, elsewhere side by side, told apart by their chips: the agent (its program and session),
// where it is (this Mac / elsewhere, and its isolation), its state, its task, what it uses and what isolates it, who
// started it and when, and Watch / Open with ⋯. Read from the workspace's detail (`workspace-show`) — no read of its own;
// ended workers come from its log. "+ Add a worker" opens its page (#/w/NAME/agents/new) and End… is the `worker-end`
// action; Take out and Move are the filing actions — all this Mac's own browser only (another computer: the commands).
// The start stays a command to copy here.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-47cfabfed13b475c.js';
import { full, mib, when } from '../core/format-b2e68384da8d2f36.js';
import { agentHash, agentsHash, canDoHash, workspaceHash } from '../core/routes-c03e6aed84ec9eb3.js';
import { isRemote } from '../core/session-76fecfa2ea8ff65b.js';
import { state } from '../core/state-1036883eb74b9520.js';
import { callout } from '../components/callout-f30e3ad8767a987a.js';
import { cmdLine } from '../components/cmd-line-ba7a45adca73f268.js';
import { confirmAction } from '../components/dialog-408f2bb247f85767.js';
import { moreMenu } from '../components/menus-b8f822d6b7817c72.js';
import { pageFailure, toast } from '../components/notices-b29072c7b381a4ec.js';
import { agentChips } from '../components/agent-frame-245e2c291e64276d.js';
import { canDoTable } from '../components/can-do-9b490f7d09c56720.js';
import { putInWorkspace, takeOut, filingRefusal, releaseCommand } from '../components/put-in-workspace-d267db0f10593bad.js';
import { restartSessionDialog } from '../components/session-actions-2fb5423b07aec4c3.js';
import { programName } from '../components/ws-panel-ea82239f147518f3.js';
import { workspacePill } from '../components/ws-marks-26369af31d4dbb6f.js';
import { addWorkerLink, endWorkerItem } from '../components/worker-end-28005159d292f76a.js';
import { openInTerminal } from './sandbox-dialogs-1e0acfa9cebba5a1.js';

/// An agent's state as a phase the dots and pills know.
function phase(s) { return ['running', 'booting', 'paused', 'asleep', 'hibernated', 'off', 'failed', 'ended'].includes(s) ? s : 'off'; }

/// What an agent runs and in which session: "Claude Code · bot mira · session claude-2".
function runsLine(a) {
  const bot = a.bot && state.bots ? state.bots.bots.find((b) => b.name === a.bot) : null;
  return [bot ? programName(bot.agent) : null, a.bot ? 'bot ' + a.bot : null, a.session ? 'session ' + a.session : null].filter(Boolean).join(' · ');
}

/// What it uses and what isolates it: the control line (a worker's), a VM's CPUs and RAM from the sandbox list when read.
function usesLine(a) {
  const parts = [];
  if (a.kind === 'sandbox' && state.overview && state.overview.sandboxes) {
    const s = state.overview.sandboxes.find((x) => x.name === a.sandbox);
    if (s) parts.push(s.cpus + ' CPU' + (s.cpus === 1 ? '' : 's') + ' · ' + mib(s.memoryMiB));
  }
  if (a.control) parts.push(a.control);
  else if (a.kind === 'elsewhere') parts.push('not run by Dozable · token only');
  else if (a.kind === 'mac' && a.isolation === 'unfenced') parts.push('no proxy · no placeholders · no guard');
  else if (a.kind === 'sandbox') parts.push('micro VM · proxy · placeholders');
  return parts;
}

/// The ⋯ of one agent: its screen, Open in Terminal, Restart, End (a live worker's command), Take out, Move.
export function agentMenuItems(d, a, opts = {}) {
  const why = filingRefusal();
  const liveWorker = a.role === 'worker' && a.task && a.state !== 'ended';
  const runningManager = a.role === 'manager' && a.state === 'running';
  const items = [];
  items.push({ label: 'Open its screen', icon: 'monitor', desc: a.kind === 'elsewhere' ? 'Where it runs and how it joins' : 'Its terminal, framed by ' + d.name,
    onSelect: () => { location.hash = agentHash(d.name, a.name); } });
  if (a.kind === 'sandbox') {
    items.push({ label: 'Open in Terminal', icon: 'square-terminal', desc: 'In your terminal app (doz attach)', disabled: isRemote() || a.state !== 'running',
      why: isRemote() ? 'Only on this Mac' : 'It is not running', onSelect: () => openInTerminal(a.sandbox, a.session || null) });
    const s = a.session || defaultSession(a.sandbox);
    items.push({ label: 'Restart', icon: 'rotate-ccw', desc: 'Its session ends and starts again — the conversation continues', disabled: !s || a.state !== 'running',
      why: a.state !== 'running' ? 'It is not running' : 'Open its screen to choose the session', onSelect: () => restartSessionDialog(a.sandbox, s) });
  } else if (a.kind === 'mac') {
    items.push({ label: 'Copy: doz attach @mac ' + a.session, icon: 'square-terminal', desc: 'Attach in a terminal on this Mac', onSelect: () => copy('doz attach @mac ' + a.session) });
    items.push({ label: 'Restart', icon: 'rotate-ccw', desc: 'Its program stops and starts again in its folder', disabled: a.state === 'gone',
      why: 'Its record is gone', onSelect: () => confirmAction('Restart ' + a.session, 'Its program on this Mac stops and starts again. Claude continues its conversation when there is one.',
        a.session, { action: 'mac-session-restart', session: a.session }) });
  }
  if (liveWorker) {
    items.push(endWorkerItem(d.name, a, opts.onDone));
  }
  items.push({ sep: true });
  const cannot = liveWorker ? 'A worker is ended, not taken out: doz worker end ' + d.name + ' ' + a.name
    : runningManager ? 'It manages ' + d.name + ' and runs: doz workspace stop ' + d.name + ' first' : why;
  items.push({ label: 'Take out of the workspace…', icon: 'log-out', desc: 'It is loose again and keeps running', disabled: !!cannot, why: cannot,
    data: { 'take-out': a.name }, onSelect: () => takeOut(d.name, a, opts) });
  const place = a.kind === 'sandbox' ? a.sandbox : a.kind === 'mac' ? '@mac/' + a.session : null;
  items.push({ label: 'Move to another workspace…', icon: 'folder-input', desc: 'Take it out, then put it in another — two steps', disabled: !!cannot || !place,
    why: cannot || 'It runs elsewhere', onSelect: () => takeOut(d.name, a, { onDone: () => { if (place) putInWorkspace(place, { running: a.state === 'running' }); if (opts.onDone) opts.onDone(); } }) });
  return items;
}

function defaultSession(sandbox) {
  const row = state.overview && state.overview.sandboxes ? state.overview.sandboxes.find((x) => x.name === sandbox) : null;
  const own = row && (row.sessionList || []).find((x) => x.isDefault);
  return own ? own.name : null;
}

async function copy(text) {
  try { await navigator.clipboard.writeText(text); toast('Copied — paste it in a terminal on this Mac'); } catch (_) { pageFailure('This browser could not copy — ' + text); }
}

function agentRow(d, a, opts) {
  const href = agentHash(d.name, a.name);
  const where = a.kind === 'elsewhere' ? 'elsewhere' : 'this Mac';
  const watch = a.kind === 'elsewhere' ? h('a', { class: 'btn sm quiet', href }, 'Open')
    : h('a', { class: 'btn sm quiet', href, 'data-agent-watch': a.name }, icon(a.state === 'running' ? 'eye' : 'monitor'), a.state === 'running' ? 'Watch' : 'Open');
  const unfenced = a.actsAsYou || (a.kind === 'mac' && a.isolation === 'unfenced');
  const runs = runsLine(a);
  return h('tr', { 'data-agent-row': a.name, 'data-kind': a.kind, class: unfenced ? 'is-unfenced' : null },
    h('td', { 'data-label': 'Agent' }, h('div', { class: 'wsa-agent' }, h('a', { href, class: 'wsa-name' }, a.name), h('span', { class: 'wsa-role' }, a.role)),
      runs ? h('div', { class: 'wsa-sub' }, runs) : null),
    h('td', { 'data-label': 'Where' }, h('div', { class: 'wsa-chips' }, h('span', { class: 'ws-chip wsa-place', 'data-place': where }, a.kind === 'elsewhere' ? '⇢ elsewhere' : 'this Mac'),
      ...agentChips(a).filter((c) => !c.matches || !c.matches('.ws-chip:not(.acts-as-you)')))),
    h('td', { 'data-label': 'State' }, h('span', { class: 'pill ph-' + phase(a.state) }, a.state), a.activity ? h('div', { class: 'wsa-sub' }, a.activity) : null),
    h('td', { 'data-label': 'Task', class: 'wsa-task', title: a.task || null }, a.task || (a.role === 'manager' ? 'runs the workspace' : h('span', { class: 'muted' }, 'adopted'))),
    h('td', { 'data-label': 'Uses · control' }, ...usesLine(a).map((x) => h('div', { class: 'wsa-uses' }, x))),
    h('td', { 'data-label': 'Started' }, h('span', { title: full(a.startedAt) }, (a.startedBy || 'you') + ' · ' + when(a.startedAt))),
    h('td', { class: 'wsa-acts' }, watch, moreMenu('More for ' + a.name, agentMenuItems(d, a, opts), { small: true }).el));
}

/// The Agents tab. o: {detail, lines (the log's), onChanged}.
export function agentsTab(o) {
  const d = o.detail;
  const opts = { onDone: o.onChanged };
  const order = (a) => (a.role === 'manager' ? 0 : a.task ? 2 : 1);
  const agents = d.agents.slice().sort((x, y) => order(x) - order(y) || x.name.localeCompare(y.name));
  const ended = (o.lines || []).filter((l) => l.action === 'worker-ended' && l.agent && !d.agents.some((a) => a.name === l.agent && a.state !== 'ended'));
  const add = addWorkerLink(d.name, [icon('plus'), 'Add a worker'], 'btn sm');
  const views = h('span', { class: 'segmented wsa-views', role: 'group', 'aria-label': 'List or grid' },
    h('button', { type: 'button', class: 'seg active', 'aria-pressed': 'true', 'data-wsa-view': 'list' }, icon('list'), 'List'),
    h('button', { type: 'button', class: 'seg', disabled: true, 'aria-disabled': 'true', 'data-wsa-view': 'grid', title: 'Grid — coming: every agent’s screen as a tile' },
      icon('layout-grid'), 'Grid', h('span', { class: 'ws-coming' }, 'coming')));
  const rows = agents.map((a) => agentRow(d, a, opts));
  rows.push(h('tr', { class: 'wsa-cloud', 'aria-disabled': 'true', 'data-agent-row': '', 'data-kind': 'cloud' },
    h('td', { 'data-label': 'Agent' }, '☁ a cloud worker'), h('td', { 'data-label': 'Where' }, h('span', { class: 'ws-chip' }, 'cloud')),
    h('td', { 'data-label': 'State' }, 'later'), h('td', { colspan: '4', class: 'muted' }, 'Where a worker run off your Mac would appear — the same row, the same chips, the same room')));
  const table = h('div', { class: 'panel wsa-panel' }, h('table', { class: 'wsa-table', 'data-agents-table': d.name },
    h('thead', null, h('tr', null, ...['Agent', 'Where', 'State', 'Task', 'Uses · control', 'Started by · when', ''].map((t) => h('th', null, t)))),
    h('tbody', null, ...rows)));
  return h('div', { class: 'wsa', 'data-ws-agents': d.name },
    h('div', { class: 'wsa-tools' }, h('p', { class: 'muted wsa-count' }, d.agents.length + ' agent' + (d.agents.length === 1 ? '' : 's') + ' in ' + d.name), h('span', { class: 'ws-sp' }), views, add),
    d.agents.length ? null : callout('info', { compact: true, title: 'No agent yet',
      body: ['A loose sandbox or session joins with Put in a workspace… (This Mac › Loose agents); a worker with ', h('code', null, 'doz worker add'), '.'] }),
    table,
    d.hidden ? h('p', { class: 'muted wsa-hidden' }, d.hidden + ' on this Mac not shown to this browser (serve.mac_sessions).') : null,
    ended.length ? h('details', { class: 'wsa-ended' }, h('summary', null, 'Ended workers (' + ended.length + ')'),
      h('ul', null, ...ended.map((l) => h('li', { 'data-ended': l.agent }, l.agent + ' — ' + l.text + ' · ', h('span', { title: full(l.at) }, when(l.at)))))) : null);
}

/// #/w/NAME/agent/AGENT when there is no page to frame: an agent elsewhere (a participant, token only — no terminal), a
/// manager not started (the command that starts it), a place gone (the log's last line about it, and Take out…), or no
/// such agent.
export async function viewWsAgent() {
  const f = state.frame;
  if (!f) return h('div', null);
  const back = h('a', { href: agentsHash(f.workspace) }, 'Its agents');
  const crumb = h('nav', { class: 'agent-crumb', 'aria-label': 'Where this agent is' }, h('a', { href: workspaceHash(f.workspace) }, f.workspace),
    h('span', { class: 'agent-crumb-sep', 'aria-hidden': 'true' }, '›'), back, h('span', { class: 'agent-crumb-sep', 'aria-hidden': 'true' }, '›'),
    h('span', { class: 'agent-crumb-here', 'aria-current': 'page' }, f.agent));
  const head = (a) => h('div', { class: 'head' }, h('h1', null, f.agent), a ? h('span', { class: 'chips' }, h('span', { class: 'ws-chip' }, a.role), ...agentChips(a)) : null);
  if (f.tab === 'can-do' && f.detail && f.row) return canDoPage(f, crumb, head);
  if (!f.detail) {
    return h('div', { class: 'wsa-card-page', 'data-agent-card': 'unreadable' }, crumb, head(null),
      callout(f.error && f.error.status === 404 ? 'warn' : 'bad', { title: f.error && f.error.status === 404 ? f.workspace + ' is not a workspace' : 'This workspace could not be read',
        body: f.error ? f.error.message || String(f.error) : '' }));
  }
  const a = f.row;
  if (!a) {
    return h('div', { class: 'wsa-card-page', 'data-agent-card': 'none' }, crumb, head(null),
      callout('warn', { title: 'No agent ' + f.agent + ' in ' + f.workspace, body: h('span', null, 'It may have been taken out or renamed. ', back, ' lists who is there.') }));
  }
  let card;
  if (a.kind === 'elsewhere') {
    card = callout('info', { title: 'Elsewhere — not run by Dozable', attrs: { 'data-agent-card': 'elsewhere' },
      body: [a.name + ' is a participant in the workspace’s rooms with its own token only; it runs on another computer, so there is no terminal here. ',
        a.bot ? 'Its Agent / Bot: ' + a.bot + '.' : ''] });
  } else if (a.state === 'not started') {
    card = callout('info', { title: a.name + ' is not started', attrs: { 'data-agent-card': 'not-started' },
      body: [d0(f) ? 'The work starts once ' + f.workspace + ' is fully set up; its start starts its manager.' : 'Its manager starts with the workspace.',
        cmdLine('doz workspace start ' + f.workspace)] });
  } else {
    let lines = [];
    try { lines = (await api('workspaces/' + encodeURIComponent(f.workspace) + '/log')).lines || []; } catch (_) { /* said without it */ }
    const last = lastLine(lines, a);
    card = callout('warn', { title: a.name + '’s place is gone', attrs: { 'data-agent-card': 'gone' },
      body: [(a.kind === 'mac' ? 'The session ' + a.session : 'The sandbox ' + a.sandbox) + ' is no longer on this Mac.',
        last ? h('p', { class: 'muted' }, 'Last in its log: ' + last) : null, cmdLine(releaseCommand(f.workspace, a.name))],
      actions: [h('button', { type: 'button', class: 'btn sm', disabled: filingRefusal() ? true : null, title: filingRefusal() || null,
        on: { click: () => takeOut(f.workspace, a, { onDone: () => { location.hash = agentsHash(f.workspace); } }) } }, icon('log-out'), 'Take out…')] });
  }
  return h('div', { class: 'wsa-card-page', 'data-agent-page': a.name }, crumb, head(a), card,
    h('dl', { class: 'facts wsa-facts' },
      h('dt', null, 'Workspace'), h('dd', null, h('a', { href: workspaceHash(f.workspace) }, f.workspace), ' ', f.detail ? workspacePill(f.detail.state, f.detail.words) : null),
      h('dt', null, 'Task'), h('dd', null, a.task || (a.role === 'manager' ? 'runs the workspace' : 'adopted')),
      h('dt', null, 'Started by'), h('dd', null, (a.startedBy || 'you') + ' · ' + when(a.startedAt))));
}
const d0 = (f) => f.detail && f.detail.state === 'setting-up';

/// #/w/NAME/agent/AGENT/can-do — what the agent can do, read afresh on every visit (`workspace-reach` for this agent: one
/// read-only request, no daemon started).
async function canDoPage(f, crumb, head) {
  const a = f.row;
  const tabs = h('div', { class: 'cando-tabs', role: 'tablist', 'aria-label': f.agent },
    h('a', { role: 'tab', class: 'ws-tab', href: agentHash(f.workspace, a.name), 'aria-selected': 'false' }, a.kind === 'elsewhere' ? 'Its card' : 'Its screen'),
    h('a', { role: 'tab', class: 'ws-tab is-on', href: canDoHash(f.workspace, a.name), 'aria-selected': 'true' }, 'Can do'));
  let reach = null, error = null;
  try { reach = await api('workspace-reach', { method: 'POST', json: { workspace: f.workspace, agent: a.name } }); } catch (e) { error = e; }
  const r = reach && reach.agents.find((x) => x.name === a.name);
  const body = error ? callout('bad', { title: 'What it can do could not be read', body: error.message || String(error) })
    : !r ? callout('info', { title: 'Not shown to this browser', body: a.name + ' runs on this Mac, and this browser is not shown its sessions (serve.mac_sessions).' })
    : canDoTable(r);
  return h('div', { class: 'wsa-card-page cando-page', 'data-cando-page': a.name }, crumb, head(a), tabs,
    h('p', { class: 'muted cando-key' }, 'Only what is true today. ', h('span', { class: 'cando-when', 'data-when': 'live' }, 'live'), ' changes now · ',
      h('span', { class: 'cando-when', 'data-when': 'restart' }, 'next start'), ' after a restart.'),
    body,
    reach && reach.notes.length ? h('p', { class: 'muted' }, reach.notes.join(' · ')) : null,
    h('div', { class: 'cando-cmds' }, cmdLine('doz workspace show ' + f.workspace + ' --can-do --agent ' + a.name)));
}
/// The log's last line about an agent.
function lastLine(lines, a) {
  for (let i = lines.length - 1; i >= 0; i--) if (lines[i].agent === a.name) return lines[i].text;
  return null;
}
