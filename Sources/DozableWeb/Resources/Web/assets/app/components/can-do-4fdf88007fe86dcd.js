// components/can-do — What an agent of a workspace can do (#/w/NAME/agent/AGENT/can-do): ONE table per agent from
// `workspace-reach`'s rows (`AgentCapabilities.rows` — an @mac agent's are exactly its session's "What this session can
// do"), each saying what it opens now and whether it changes live or at the next start. The last two are its permissions
// (allow · ask · never, the counts `doz permissions show W --agent A` prints) and its ceiling (each cap and whose it is):
// read only here — changed in a terminal, and none is enforced yet. An unfenced agent's control row is the warning chip
// "acts as you". Nothing here shows a secret: names only.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { cmdLine } from './cmd-line-0addb11225f36cdd.js';

function editable(e) {
  return h('span', { class: 'cando-when', 'data-when': e }, e === 'live' ? 'live' : 'next start');
}

/// The table for one agent of the reach answer (`a`: an agent of WebWorkspaceReach).
export function canDoTable(a) {
  const rows = a.capabilities.map((c) => {
    const warn = c.id === 'control' && a.actsAsYou;
    return h('tr', { 'data-cando': c.id, class: warn ? 'is-warn' : null },
      h('th', { scope: 'row', 'data-label': 'Capability' }, c.name),
      h('td', { 'data-label': 'Now' }, warn ? h('span', { class: 'ws-chip acts-as-you' }, icon('triangle-alert'), c.state) : h('span', { class: 'cando-state' }, c.state)),
      h('td', { 'data-label': 'What it opens', class: 'cando-sentence' }, c.sentence, c.link ? h('div', { class: 'cando-link' }, cmdLine(c.link)) : null),
      h('td', { 'data-label': 'Changes' }, editable(c.editable)));
  });
  return h('div', { class: 'panel cando-panel' }, h('table', { class: 'cando-table', 'data-cando-table': a.name },
    h('thead', null, h('tr', null, ...['Capability', 'Now', 'What it opens', 'Changes'].map((t) => h('th', { scope: 'col' }, t)))),
    h('tbody', null, ...rows)));
}
