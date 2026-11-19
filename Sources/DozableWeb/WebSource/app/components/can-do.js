// components/can-do — What an agent of a workspace can do (#/w/NAME/agent/AGENT/can-do): ONE table per agent from
// `workspace-reach`'s rows (`AgentCapabilities.rows` — an @mac agent's are exactly its session's "What this session can
// do"), each saying what it opens now and whether it changes live or at the next start. Only what is true today: the two
// rows that come later (Permissions — allow · ask · never — and the ceiling) are drawn disabled with "later" and hold no
// data. An unfenced agent's control row is the warning chip "acts as you". Nothing here shows a secret: names only.
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { cmdLine } from './cmd-line.js';

/// The two rows that come later — drawn, never data.
export const LATER_ROWS = [
  { id: 'permissions', name: 'Permissions (allow · ask · never)', sentence: 'What it may do here, by role, and who decides — later.' },
  { id: 'ceiling', name: 'Ceiling', sentence: 'The most it may ever do, whatever it is granted — later.' },
];

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
  for (const l of LATER_ROWS) {
    rows.push(h('tr', { 'data-cando': l.id, class: 'is-later', 'aria-disabled': 'true', title: l.name + ' — later' },
      h('th', { scope: 'row', 'data-label': 'Capability' }, l.name),
      h('td', { 'data-label': 'Now' }, h('span', { class: 'ws-coming' }, 'later')),
      h('td', { 'data-label': 'What it opens', class: 'cando-sentence muted' }, l.sentence),
      h('td', { 'data-label': 'Changes' }, '—')));
  }
  return h('div', { class: 'panel cando-panel' }, h('table', { class: 'cando-table', 'data-cando-table': a.name },
    h('thead', null, h('tr', null, ...['Capability', 'Now', 'What it opens', 'Changes'].map((t) => h('th', { scope: 'col' }, t)))),
    h('tbody', null, ...rows)));
}
