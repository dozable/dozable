// views/doctor — Doctor.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { api } from '../core/api-fa1e04fa0a2ef189.js';
import { state } from '../core/state-3b49d54e8d9b6a73.js';
import { panel, table } from '../components/blocks-6b2d43608253a84f.js';
import { btn } from '../components/button-8109d54546d946d3.js';
import { statusPill } from '../components/pills-3ea61ab9c4db0bb0.js';
import { tildeIn } from '../core/paths-074fefdb8b1d48aa.js';

export async function viewDoctor() {
  const checks = await api('doctor');
  const rows = checks.map((c) => h('tr', null, h('td', null, statusPill(c.status)), h('td', null, c.check), h('td', null, tildeIn(c.detail))));
  return h('div', null,
    h('div', { class: 'head' }, h('h1', null, 'Doctor'),
      btn('Run onboarding again', () => { state.wiz = null; location.hash = '#/onboarding'; },
        { title: 'The setup wizard: checks, the Claude account, settings, images — it prepares only what is missing' })),
    h('p', { class: 'sub' }, 'doz doctor: this Mac, the store, the daemon and the Claude login (re-checked at most every 30 s).'),
    panel(table(['', 'Check', 'Detail'], rows)));
}
