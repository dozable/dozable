// views/this-mac — This Mac (#/mac): everything shared by every workspace, one line per page — what runs, its sessions and
// sandboxes, the loose agents, templates, images, accounts, resources, logs, Doctor, the chat server, devices, settings,
// the daemon. Built only from what the page reads anyway (the overview, the sessions on this Mac, the accounts, the
// operations, chat's status) plus the loose agents; nothing is measured or checked on arrival (Resources, Doctor).
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-dbad41ec6656fd00.js';
import { plural } from '../core/format-b2e68384da8d2f36.js';
import { state } from '../core/state-58b070d3f17c1c53.js';
import { loadLoose } from '../core/workspaces-ad329f235e66b166.js';
import { brokenCount } from '../components/account-problems-c568a10734e5fa81.js';
import { hostAction } from '../components/host-cda95f17682bb7cd.js';

function row(href, glyph, title, line, extra) {
  const k = href ? h('a', { href, class: 'tm-k', 'data-thismac-link': href }, icon(glyph), h('span', null, title))
    : h('span', { class: 'tm-k' }, icon(glyph), h('span', null, title));
  return h('div', { class: 'tm-row', role: 'listitem' }, k, h('span', { class: 'tm-v' }, ...[].concat(line)), extra || null);
}

export async function viewThisMac() {
  const o = state.overview;
  const sbx = o ? o.sandboxes : [];
  const running = sbx.filter((s) => s.phase === 'running' || s.phase === 'booting').length;
  let mac = null;
  try { mac = (await api('mac/sessions')).sessions || []; } catch (_) { /* another computer that may not see them */ }
  let loose = null;
  try { loose = await loadLoose(0); } catch (_) { /* said below */ }
  const live = mac ? mac.filter((s) => s.state === 'running') : [];
  const fenced = live.filter((s) => s.fenced).length, open = live.length - fenced;
  const broken = state.accounts && o ? brokenCount(state.accounts, sbx) : 0;
  const failedOp = [...state.ops.values()].some((x) => x.state === 'failed');
  const chat = state.chat.status ? state.chat.status.state : null;
  const host = o && o.host;
  const res = $('res-total');
  const runs = [h('a', { href: '#/mac/sandboxes', 'data-thismac-link': '#/mac/sandboxes' }, plural(running, 'sandbox', 'sandboxes') + ' running of ' + sbx.length)];
  if (mac) runs.push(' · ', h('a', { href: '#/mac/here', 'data-thismac-link': '#/mac/here' },
    plural(live.length, 'session', 'sessions') + ' on this Mac' + (live.length ? ' (' + fenced + ' fenced, ' + open + ' unfenced)' : '')));
  const rows = [
    row(null, 'activity', 'What runs', runs),
    row('#/mac/sessions', 'layout-grid', 'Sessions', 'every agent’s screen, as tiles'),
    row('#/mac/loose', 'briefcase', 'Loose agents' + (loose ? ' (' + loose.loose.length + ')' : ''),
      loose ? (loose.loose.length ? 'not in any workspace: ' + loose.loose.slice(0, 4).map((a) => a.name).join(' · ') + (loose.loose.length > 4 ? ' …' : '') : 'none — every sandbox and session is in a workspace')
        : 'could not be listed'),
    row('#/mac/templates', 'monitor', 'Templates and recipes', 'the recipes on this Mac, the catalogue, Quick try'),
    row('#/mac/images', 'layers', 'Images', 'images, bases and their lineage'),
    row('#/mac/accounts', 'key-round', 'Accounts & keys', broken ? plural(broken, 'key or sign-in', 'keys or sign-ins') + ' a sandbox relies on do not work' : 'the accounts and keys agents use'),
    row('#/mac/resources', 'cylinder', 'Resources', res && !res.hidden && res.textContent ? 'Dozable uses ' + res.textContent + ' of disk' : 'every byte Dozable uses — measured on its page'),
    row('#/mac/logs/operations', 'list-checks', 'Logs', failedOp ? 'an operation failed — operations, activity, notifications, metrics' : 'operations, activity, notifications, metrics'),
    row('#/mac/doctor', 'stethoscope', 'Doctor', 'the checks of this Mac, the store and the daemon'),
    row(chat && chat !== 'off' && chat !== 'remote' ? '#/chat' : null, 'message-square', 'The chat server',
      chat === null ? 'not read yet' : chat === 'remote' ? 'not shared with this browser' : chat === 'off' ? 'off — doz chat on turns it on' : chat),
    row('#/mac/devices', 'user-round', 'Devices', 'the dashboard on your other computers, tablets and phones'),
    row('#/mac/settings', 'settings', 'Settings', 'every setting, searchable'),
    row(null, 'power', 'The daemon', host ? (host.running ? 'running · doz ' + (host.version || '?') : 'not running') : '—', hostAction(host)),
  ];
  return h('div', { class: 'thismac-page', 'data-thismac': '' },
    h('div', { class: 'head' }, h('h1', null, 'This Mac')),
    h('p', { class: 'sub' }, 'What every workspace shares: this Mac’s sandboxes and sessions, templates, images, accounts and keys, and Dozable itself.'),
    h('div', { class: 'panel tm-list', role: 'list' }, ...rows));
}
