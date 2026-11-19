// views/loose — This Mac › Loose agents (#/mac/loose): each sandbox and session on this Mac in no workspace, with the
// command that adopts one. Nothing moves by itself: adopting changes only the workspace's record.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { state } from '../core/state-3b49d54e8d9b6a73.js';
import { loadLoose } from '../core/workspaces-783a2bc3382b1f4d.js';
import { panel, table } from '../components/blocks-6b2d43608253a84f.js';
import { callout } from '../components/callout-f30e3ad8767a987a.js';
import { cmdLine } from '../components/cmd-line-73c7c08d700ea099.js';

export async function viewLoose() {
  const l = await loadLoose(0);
  const rows = l.loose.map((a) => {
    const session = a.kind === 'mac' && a.name.startsWith('@mac/') ? a.name.slice(5) : null;
    const href = session ? '#/mac/here/' + encodeURIComponent(session) : '#/sandbox/' + a.name + '/~home';
    return h('tr', { 'data-loose': a.name },
      h('td', null, h('a', { href }, a.name)),
      h('td', null, session ? 'on this Mac' : 'micro VM'),
      h('td', null, h('span', { class: 'pill ph-' + phaseOf(a.state) }, a.state)),
      h('td', null, h('a', { href, class: 'btn sm quiet' }, 'Open')),
      h('td', null, cmdLine('doz workspace adopt WORKSPACE ' + a.name)));
  });
  const ws = state.workspaces ? state.workspaces.workspaces.length : 0;
  return h('div', { class: 'loose-page', 'data-loose-page': '' },
    h('div', { class: 'head' }, h('h1', null, 'Loose agents')),
    h('p', { class: 'sub' }, 'The sandboxes and sessions on this Mac that are not in any workspace' + (ws ? '' : ' — there are no workspaces yet') + '.'),
    callout('info', { title: 'Nothing moves by itself', body: 'A sandbox or a session stays as it is until you adopt it into a workspace — only the workspace’s record changes. Run the command in a terminal on this Mac, with the workspace’s name.' }),
    l.hidden ? callout('info', { compact: true, body: l.hidden + ' on this Mac not shown to this browser (serve.mac_sessions).' }) : null,
    panel(table(['Name', 'Kind', 'State', '', 'To adopt it'], rows), 'Every sandbox and session on this Mac is in a workspace.'));
}
function phaseOf(s) { return ['running', 'booting', 'paused', 'asleep', 'hibernated', 'off', 'failed', 'ended'].includes(s) ? s : 'off'; }
