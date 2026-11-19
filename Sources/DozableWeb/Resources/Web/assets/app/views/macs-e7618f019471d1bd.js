// views/macs — This Mac › Your Macs (#/mac/macs): the other Macs' dashboards the machine picker lists, as `doz ui macs ls`
// has them, with the commands that add and remove one (the list is changed in a terminal on this Mac only). Opening one
// is a plain link to its origin in a new tab: that Mac's own sign-in applies, nothing of this Mac's is passed.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-6c35c6a6d28e6ec4.js';
import { when } from '../core/format-b2e68384da8d2f36.js';
import { panel, table } from '../components/blocks-6b2d43608253a84f.js';
import { callout } from '../components/callout-f30e3ad8767a987a.js';
import { cmdLine } from '../components/cmd-line-88321c21bba53efb.js';
import { macStatus } from '../components/mac-picker-6bb74ef677d26d4e.js';

const RESULTS = { reachable: 'answered', 'not-dozable': 'not a Dozable dashboard', redirected: 'redirects to https', refused: 'nothing answered',
  timeout: 'no answer in 3 s', tls: 'certificate not accepted', dns: 'name not found' };

export async function viewMacs() {
  const l = await api('macs');
  const others = l.macs.filter((m) => m.origin !== location.origin);
  const rows = others.map((m) => {
    const st = macStatus(m);
    return h('tr', { 'data-mac': m.name },
      h('td', null, h('span', { class: 'mac-dot' + (st.fresh ? ' is-seen' : ''), 'aria-hidden': 'true' }), ' ', h('b', null, m.name),
        m.reportedName && m.reportedName.toLowerCase() !== m.name ? h('span', { class: 'mac-says' }, ' (says: ' + m.reportedName + ')') : null),
      h('td', null, h('code', { class: 'mac-host' }, m.origin), m.scheme === 'http' ? h('span', { class: 'mac-tag' }, 'plain HTTP') : null),
      h('td', null, m.lastSeenAt ? when(m.lastSeenAt) : 'never'),
      h('td', null, m.lastCheckAt ? (RESULTS[m.lastResult] || '—') + ' · ' + when(m.lastCheckAt) : 'never checked'),
      h('td', null, h('a', { href: m.origin + '/', target: '_blank', rel: 'noopener noreferrer', referrerpolicy: 'no-referrer', class: 'btn sm quiet',
        'data-mac-open': m.name }, 'Open ', icon('external-link'))),
      h('td', null, cmdLine('doz ui macs rm ' + m.name)));
  });
  const here = (l.thisMac && l.thisMac.name) || 'this Mac';
  return h('div', { class: 'macs-page', 'data-macs-page': '' },
    h('div', { class: 'head' }, h('h1', null, 'Your Macs')),
    h('p', { class: 'sub' }, 'The other Macs whose dashboards “Dozable · ' + here + '” opens. Picking one opens its own dashboard in a new tab, where you sign in to that Mac; this Mac passes nothing to it.'),
    panel(table(['Mac', 'Address', 'Last seen', 'Last check', '', 'To remove it'], rows), 'No other Macs yet — add one below.'),
    h('section', { class: 'macs-add', 'data-macs-add': '' },
      h('h2', null, 'Add a Mac'),
      h('p', null, 'Its Tailscale name or LAN address. On that Mac run ', h('code', null, 'doz ui --lan'), ' or ', h('code', null, 'doz ui publish tailscale'),
        '; this browser signs in there with ', h('code', null, 'doz ui share'), ' on that Mac.'),
      h('p', null, cmdLine('doz ui macs add NAME ADDRESS')),
      h('p', { class: 'sub' }, 'For example ', h('code', null, 'doz ui macs add mini mini.example.ts.net'), '. Whether a Mac answers is checked when you add it, and again with ',
        h('code', null, 'doz ui macs check'), ' — never by this page.')),
    callout('info', { compact: true, title: 'A link, nothing more', body: 'Each Mac keeps its own daemon, workspaces, agents and keys. Nothing is shared between Macs, and no key, cookie or link of this Mac’s is ever passed to another.' }));
}
