// components/ws-panel — A workspace page's side panel, "who's here and in what": its agents (state, name, role, where and
// how isolated — micro VM, fenced, unfenced, elsewhere — "acts as you" for an unfenced one, a worker's task and what
// isolates it; each links to its screen in the workspace, #/w/NAME/agent/AGENT), every worker under the main room; "In this
// room" (the chat surface's own people list, moved here — a slot); its folders; its network. "+ Worker" shows the
// command. Also the meta line each sender's name carries in the room (`agentMeta`).
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { agentHash, agentsHash } from '../core/routes-6d0d22795b086695.js';
import { cmdLine } from './cmd-line-9cf2774fd18363c4.js';

const PROGRAMS = { 'claude-code': 'Claude Code', codex: 'Codex' };
/// An agent program as a person reads it (`claude-code` → Claude Code).
export const programName = (p) => PROGRAMS[p] || p || '';

/// Where an agent runs and how it is isolated: micro VM, fenced, unfenced, elsewhere; an adopted one with none recorded
/// says its place (a sandbox is a micro VM; a session on this Mac is on this Mac).
export function isolationWords(a) {
  if (a.kind === 'elsewhere') return 'elsewhere';
  if (a.isolation === 'vm') return 'micro VM';
  if (a.isolation === 'fenced' || a.isolation === 'unfenced') return a.isolation;
  return a.kind === 'sandbox' ? 'micro VM' : 'on this Mac';
}

/// The meta line under a sender's name in the room: role · agent program · isolation · session — the program from the
/// Agents / Bots list for a bot; an adopted agent with no bot shows its place only; a person or someone not in the
/// workspace, none. {text, actsAsYou, title} | null.
export function agentMeta(detail, bots, name) {
  const a = detail && detail.agents.find((x) => x.name === name);
  if (!a) return null;
  const where = a.kind === 'sandbox' ? 'sandbox ' + a.sandbox : a.kind === 'mac' ? 'session ' + a.session : 'elsewhere';
  if (!a.bot && !a.task && a.role !== 'manager') return { text: isolationWords(a) + ' · ' + where, actsAsYou: a.actsAsYou, title: 'Adopted into the workspace' };
  const bot = a.bot && bots ? bots.find((b) => b.name === a.bot) : null;
  const parts = [a.role, bot ? programName(bot.agent) : null, isolationWords(a), a.kind === 'elsewhere' ? null : where].filter(Boolean);
  return { text: parts.join(' · '), actsAsYou: a.actsAsYou, title: a.task ? 'Its task: ' + a.task : null };
}

/// An agent's state as a phase the dots know (a sandbox's phase; a session's running / ended / gone).
function phase(s) {
  return ['running', 'booting', 'paused', 'asleep', 'hibernated', 'off', 'failed', 'ended'].includes(s) ? s : 'off';
}

function agentRow(w, a) {
  // Its screen in the workspace (#/w/NAME/agent/AGENT): its sandbox's or its session's page, framed.
  const href = agentHash(w, a.name);
  const name = h('a', { href, class: 'ws-agent-name', title: 'Open its screen — ' + (a.kind === 'sandbox' ? 'its sandbox' : a.kind === 'mac' ? 'its session on this Mac' : 'where it runs') }, a.name);
  const iso = isolationWords(a);
  return h('li', { class: 'ws-agent', 'data-ws-agent': a.name, 'data-iso': iso },
    h('span', { class: 'ph-dot ph-' + phase(a.state), role: 'img', 'aria-label': a.state + (a.activity ? ' · ' + a.activity : '') }),
    h('div', { class: 'ws-agent-body' },
      h('div', { class: 'ws-agent-top' }, name, h('span', { class: 'ws-agent-role' }, a.role + (a.activity ? ' · ' + a.activity : a.state === 'running' ? '' : ' · ' + a.state))),
      h('div', { class: 'ws-agent-chips' },
        h('span', { class: 'ws-iso ws-iso-' + iso.replace(/ /g, '-') }, iso),
        a.actsAsYou ? h('span', { class: 'ws-chip acts-as-you', title: 'Unfenced on this Mac: it acts as you' }, icon('triangle-alert'), 'acts as you') : null),
      a.task ? h('div', { class: 'ws-agent-task', title: a.task }, a.task) : null,
      a.control ? h('div', { class: 'ws-agent-control' }, a.control) : null));
}

/// o: {detail, mainRoom (its name, or null), peopleSlot (the element "In this room" lives in)}.
export function wsPanel(o) {
  const d = o.detail;
  const managers = d.agents.filter((a) => a.role === 'manager');
  const workers = d.agents.filter((a) => a.role === 'worker' && a.task);
  const adopted = d.agents.filter((a) => !managers.includes(a) && !workers.includes(a));
  const cmd = h('div', { class: 'ws-add-worker', hidden: true }, cmdLine('doz worker add ' + d.name + ' --task "…"'),
    h('p', { class: 'muted' }, 'In a terminal on this Mac, once the work has started.'));
  const add = h('button', { type: 'button', class: 'btn sm quiet', 'aria-expanded': 'false',
    on: { click: () => { cmd.hidden = !cmd.hidden; add.setAttribute('aria-expanded', String(!cmd.hidden)); } } }, icon('plus'), 'Worker');
  const agents = h('section', { class: 'ws-box', 'aria-label': 'Agents' },
    h('h2', { class: 'ws-box-h' }, icon('bot'), h('a', { href: agentsHash(d.name), class: 'ws-box-link', title: 'The Agents tab' }, 'Agents'),
      h('span', { class: 'ws-box-n' }, String(d.agents.length))),
    d.agents.length ? h('ul', { class: 'ws-agents' }, ...managers.map((a) => agentRow(d.name, a)), ...adopted.map((a) => agentRow(d.name, a))) : h('p', { class: 'muted' }, 'No agent yet.'),
    workers.length ? h('div', { class: 'ws-sub' }, 'Workers — in ' + (o.mainRoom ? '# ' + o.mainRoom : 'the main room')) : null,
    workers.length ? h('ul', { class: 'ws-agents' }, ...workers.map((a) => agentRow(d.name, a))) : null,
    d.hidden ? h('p', { class: 'muted ws-hidden' }, d.hidden + ' on this Mac not shown to this browser (serve.mac_sessions).') : null,
    h('div', { class: 'ws-box-acts' }, add), cmd);
  const folders = h('section', { class: 'ws-box', 'aria-label': 'Folders' },
    h('h2', { class: 'ws-box-h' }, icon('folder'), 'Folders'),
    d.folders.length ? h('ul', { class: 'ws-folders' }, ...d.folders.map((f) => h('li', { 'data-ws-folder': f.path },
      h('span', { class: 'ws-path', title: f.path }, tildePath(f.path)), h('span', { class: 'muted' }, ' · ' + f.mode + (f.main ? ' · main' : '')))))
      : h('p', { class: 'muted' }, 'None — a workspace may work on no folder.'));
  const network = h('section', { class: 'ws-box', 'aria-label': 'Network' },
    h('h2', { class: 'ws-box-h' }, icon('shield'), 'Network'),
    h('p', { class: 'ws-net', 'data-ws-network': d.network || 'locked' }, d.network ? d.network + ' — its agents’ preset' : 'locked — its agents’ preset (the default)'));
  const people = h('section', { class: 'ws-box ws-people' }, o.peopleSlot);
  return h('div', { class: 'ws-panel-in' }, agents, people, folders, network);
}
