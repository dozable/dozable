// views/doctor — Doctor.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { api } from '../core/api-0560a03cb0de25ef.js';
import { state } from '../core/state-dde742b9b2d6390c.js';
import { panel, table } from '../components/blocks-6b2d43608253a84f.js';
import { btn } from '../components/button-f435595b4098d043.js';
import { statusPill } from '../components/pills-68accdd74ee5a3c8.js';
import { tildeIn } from '../core/paths-074fefdb8b1d48aa.js';

export async function viewDoctor() {
  const checks = await api('doctor');
  const rows = checks.map((c) => h('tr', null, h('td', null, statusPill(c.status)), h('td', null, c.check), h('td', null, tildeIn(c.detail))));
  return h('div', null,
    h('div', { class: 'head' }, h('h1', null, 'Doctor'),
      btn('Run onboarding again', () => { state.wiz = null; location.hash = '#/onboarding'; },
        { title: 'The setup wizard: checks, the Claude account, settings, images — it prepares only what is missing' })),
    h('p', { class: 'sub' }, 'doz doctor: this Mac, the store, the host and the Claude login (re-checked at most every 30 s).'),
    panel(table(['', 'Check', 'Detail'], rows)));
}
