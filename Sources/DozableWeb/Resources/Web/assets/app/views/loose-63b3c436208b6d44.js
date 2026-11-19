// views/loose — This Mac › Loose agents (#/mac/loose): each sandbox and session on this Mac in no workspace, with "Put in a
// workspace…" (components/put-in-workspace.js — this Mac's own browser only; the command that does the same under "Show
// the command"). Nothing moves by itself: filing changes only the workspace's record.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { state } from '../core/state-dee60cc8f4c9cdbe.js';
import { loadLoose } from '../core/workspaces-b3af0b563b1896fb.js';
import { panel, table } from '../components/blocks-6b2d43608253a84f.js';
import { callout } from '../components/callout-f30e3ad8767a987a.js';
import { cmdLine } from '../components/cmd-line-9551cfef19138751.js';
import { adoptCommand, filingRefusal, putInButton } from '../components/put-in-workspace-bf004777b2027468.js';

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
      // Another computer cannot file it: the button is disabled and says so, and the command is there to copy.
      h('td', { class: 'loose-acts' }, putInButton(a.name, { running: a.state === 'running' }), filingRefusal() ? cmdLine(adoptCommand(null, a.name)) : null));
  });
  const ws = state.workspaces ? state.workspaces.workspaces.length : 0;
  return h('div', { class: 'loose-page', 'data-loose-page': '' },
    h('div', { class: 'head' }, h('h1', null, 'Loose agents')),
    h('p', { class: 'sub' }, 'The sandboxes and sessions on this Mac that are not in any workspace' + (ws ? '' : ' — there are no workspaces yet') + '.'),
    callout('info', { title: 'Nothing moves by itself', body: 'A sandbox or a session stays as it is until you put it in a workspace — only the workspace’s record changes, and it keeps running as it is.'
      + (filingRefusal() ? ' ' + filingRefusal() + ': run the command in a terminal on this Mac.' : '') }),
    l.hidden ? callout('info', { compact: true, body: l.hidden + ' on this Mac not shown to this browser (serve.mac_sessions).' }) : null,
    panel(table(['Name', 'Kind', 'State', '', 'Its workspace'], rows), 'Every sandbox and session on this Mac is in a workspace.'));
}
function phaseOf(s) { return ['running', 'booting', 'paused', 'asleep', 'hibernated', 'off', 'failed', 'ended'].includes(s) ? s : 'off'; }
