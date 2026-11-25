// views/ws-network — A workspace's Network & secrets tab (#/w/NAME/network): "what can this workspace reach?" in one place,
// per agent — its preset and the sites beyond it, what it was refused lately (with Allow for that agent, or For all), this
// Mac's ports and the forwarded ones, the secrets held for its agents BY NAME (where each goes and, a given one, its
// fingerprint — this Mac's own browser; another computer sees a count) and the accounts used. Read afresh on every visit
// (`POST /api/v1/workspace-reach`: one read-only request, no daemon started). Allow is one action per agent — a micro VM's
// `net-policy`, a fenced session's `mac-net-policy` (this Mac's own browser only); unfenced and elsewhere cannot be limited.
// Nothing here shows a secret.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { api } from '../core/api-47cfabfed13b475c.js';
import { when } from '../core/format-b2e68384da8d2f36.js';
import { actOrThrow, waitForOp } from '../core/operations-47321c2f8a98caa2.js';
import { canDoHash } from '../core/routes-c03e6aed84ec9eb3.js';
import { isRemote } from '../core/session-d2120671b8ea9d60.js';
import { callout } from '../components/callout-a906e34ef11cba9d.js';
import { cmdLine } from '../components/cmd-line-10b1a69c2a5bd0f5.js';
import { pageFailure, toast } from '../components/notices-8353278a02ed4176.js';

const presetWord = (p) => (p === 'agent' ? 'standard' : p || 'custom');
const sessionOf = (a) => (a.place.startsWith('@mac/') ? a.place.slice(5) : a.place);

/// The command that allows `grant` for agent `a` (what Allow sends, or what to type where Allow cannot).
export function allowCommand(a, grant) {
  return a.kind === 'mac' ? 'doz net allow @mac --session ' + sessionOf(a) + ' ' + grant : 'doz net allow ' + a.place + ' ' + grant;
}

/// What Allow does for one agent: {body} — the one action —, or {why} with the command to copy.
export function allowFor(a, grant) {
  if (!a.network.proxied) return { why: a.kind === 'elsewhere' ? 'Not run by Dozable — it cannot be limited here' : 'Unfenced — it cannot be limited: it reaches the network as you do' };
  if (a.kind === 'sandbox') return { body: { action: 'net-policy', sandbox: a.place, grant: [grant] } };
  if (a.kind === 'mac') {
    if (isRemote()) return { why: 'A session on this Mac is changed only in this Mac’s own browser', cmd: allowCommand(a, grant) };
    if (!grant.startsWith('site:')) return { why: 'A permission is changed in a terminal on this Mac', cmd: allowCommand(a, grant) };
    return { body: { action: 'mac-net-policy', session: sessionOf(a), grant: [grant] } };
  }
  return { why: 'It cannot be limited here' };
}

/// Send the actions (one per agent), wait for them, say how each ended, then read the page again.
async function allow(list, batch, again) {
  const ends = [];
  for (const body of list) {
    try { ends.push(await waitForOp(await actOrThrow(batch ? { ...body, batch: true } : body), 120)); } catch (e) { ends.push({ state: 'failed', text: e.message || String(e) }); }
  }
  const bad = ends.filter((e) => !e || e.state !== 'done');
  if (bad.length) pageFailure(bad.map((e) => (e ? e.text : 'no answer yet — Operations shows how it ends')).join(' · '));
  else toast(ends.map((e) => e.text).join(' · '));
  await again();
}

function permissionsTable(r) {
  const rows = r.agents.map((a) => {
    const n = a.network;
    const refused = !n.proxied ? '—' : r.refusalsKnown ? String(n.refused.reduce((t, x) => t + x.count, 0)) : 'not known';
    return h('tr', { 'data-net-agent': a.name },
      h('th', { scope: 'row', 'data-label': 'Agent' }, h('a', { href: canDoHash(r.workspace, a.name) }, a.name), ' ', h('span', { class: 'wsa-role' }, a.role)),
      h('td', { 'data-label': 'Network' }, n.proxied ? presetWord(n.preset) + (n.live ? '' : ' · next start')
        : a.kind === 'elsewhere' ? 'not run by Dozable' : h('span', { class: 'ws-chip acts-as-you' }, icon('triangle-alert'), 'not limited, not logged')),
      h('td', { 'data-label': 'Plus' }, n.sites.length ? n.sites.join(', ') : '—'),
      h('td', { 'data-label': 'Refused' }, refused));
  });
  rows.push(h('tr', { class: 'is-default', 'data-net-agent': '~new' },
    h('th', { scope: 'row', 'data-label': 'Agent' }, 'new workers'),
    h('td', { 'data-label': 'Network' }, presetWord(r.defaults.network) + ' · ' + r.defaults.isolation),
    h('td', { 'data-label': 'Plus' }, 'the room'),
    h('td', { 'data-label': 'Refused' }, h('span', { class: 'muted' }, 'unchanged by Allow'))));
  return h('div', { class: 'panel wsn-panel' }, h('table', { class: 'wsn-table', 'data-wsn': 'permissions' },
    h('thead', null, h('tr', null, ...['Agent', 'Network', 'Plus', 'Refused lately'].map((t) => h('th', { scope: 'col' }, t)))), h('tbody', null, ...rows)));
}

function refusedList(r, again) {
  if (!r.refusalsKnown) return callout('info', { compact: true, attrs: { 'data-wsn-refused': 'unknown' }, body: 'What each agent was refused is not known: no daemon is running.' });
  const items = [];
  for (const a of r.agents) for (const x of a.network.refused) items.push({ a, x });
  if (!items.length) return h('p', { class: 'muted', 'data-wsn-refused': '0' }, 'Nothing was refused lately.');
  return h('ul', { class: 'wsn-refused', 'data-wsn-refused': String(items.length) }, ...items.map(({ a, x }) => {
    const one = allowFor(a, x.grant);
    const all = r.agents.filter((b) => !b.network.sites.includes(x.grant.replace(/^site:/, '')) && allowFor(b, x.grant).body);
    const btnOne = one.body
      ? h('button', { type: 'button', class: 'btn sm', 'data-allow-one': a.name + ' ' + x.grant, on: { click: () => allow([one.body], false, again) } }, 'Allow for ' + a.name)
      : h('button', { type: 'button', class: 'btn sm', disabled: true, title: one.why + (one.cmd ? ': ' + one.cmd : ''), 'data-allow-one': a.name + ' ' + x.grant }, 'Allow for ' + a.name);
    const btnAll = h('button', { type: 'button', class: 'btn sm quiet', 'data-allow-all': x.grant, 'data-allow-count': String(all.length), disabled: all.length < 2 ? true : null,
      title: all.length < 2 ? 'For all: no other agent here can be limited' : 'One change for each of ' + all.map((b) => b.name).join(', '),
      on: { click: () => allow(all.map((b) => allowFor(b, x.grant).body), true, again) } }, 'For all (' + all.length + ')');
    return h('li', { 'data-refusal': a.name + ' ' + x.host },
      h('span', { class: 'wsn-what' }, h('b', null, a.name), ' → ', x.host + (x.port ? ':' + x.port : ''), h('span', { class: 'muted' }, ' ×' + x.count + (x.lastAt ? ' · ' + when(x.lastAt) : ''))),
      h('span', { class: 'ws-sp' }), btnOne, btnAll,
      one.cmd ? cmdLine(one.cmd) : null);
  }));
}

function portsBlock(r) {
  const lines = [];
  for (const a of r.agents) {
    if (a.network.hostPorts.length) lines.push(h('li', { 'data-host-ports': a.name }, a.name + ': this Mac’s ' + a.network.hostPorts.join(', ') + ' (as host.dozable.internal:PORT)'));
    for (const f of a.network.forwarded) lines.push(h('li', { 'data-forwarded': a.name + ' ' + f.port }, a.name + ':' + f.port + ' → this Mac’s localhost' + (f.local ? ':' + f.local : ' (while it runs)')));
  }
  return h('div', null, lines.length ? h('ul', { class: 'wsn-ports' }, ...lines) : h('p', { class: 'muted' }, 'None.'),
    h('p', { class: 'muted' }, 'A port is forwarded out with ', h('code', null, 'doz ports add SANDBOX PORT'), '; this Mac’s ports are given when it starts (--host-port).'));
}

function heldBlock(r) {
  const remote = isRemote();
  const add = h('button', { type: 'button', class: 'btn sm', disabled: true, 'aria-disabled': 'true', title: 'Later — today a secret is given when an agent starts' },
    icon('plus'), 'Add a secret', h('span', { class: 'ws-coming' }, 'later'));
  const today = cmdLine('doz run @mac --secret VAR,src=FILE,to=HOST:PORT -- …');
  if (remote) {
    const counts = r.agents.filter((a) => a.heldCount).map((a) => h('li', { 'data-held-count': a.name }, a.name + ': ' + a.heldCount + ' held'));
    return h('div', null, counts.length ? h('ul', null, ...counts) : h('p', { class: 'muted' }, 'None.'),
      h('p', { class: 'muted' }, 'Their names and where they go are shown only in this Mac’s own browser.'), h('div', { class: 'wsn-add' }, add));
  }
  const rows = [];
  for (const a of r.agents) for (const s of a.held) {
    rows.push(h('tr', { 'data-held': s.name + ' ' + a.name },
      h('th', { scope: 'row', 'data-label': 'Name' }, h('code', null, s.name)),
      h('td', { 'data-label': 'For' }, a.name),
      h('td', { 'data-label': 'To' }, s.kind === 'given' ? s.to : 'the room'),
      h('td', { 'data-label': 'Kind' }, s.kind === 'given' ? 'given at its start' : 'its chat token — automatic'),
      h('td', { 'data-label': 'Fingerprint' }, s.fingerprint ? h('code', null, s.fingerprint + '…') : '—')));
  }
  return h('div', null, rows.length
    ? h('div', { class: 'panel wsn-panel' }, h('table', { class: 'wsn-table', 'data-wsn': 'held' },
      h('thead', null, h('tr', null, ...['Name', 'For', 'To', 'Kind', 'Fingerprint'].map((t) => h('th', { scope: 'col' }, t)))), h('tbody', null, ...rows)))
    : h('p', { class: 'muted' }, 'None.'),
  h('div', { class: 'wsn-add' }, add, h('span', { class: 'muted' }, 'Today: '), today));
}

function accountsBlock(r) {
  const by = new Map();
  for (const a of r.agents) if (a.account) by.set(a.account, [...(by.get(a.account) || []), a.name]);
  if (!by.size) return h('p', { class: 'muted' }, 'None given by Dozable.');
  return h('ul', { class: 'wsn-accounts' }, ...[...by.entries()].map(([acc, names]) => h('li', { 'data-account': acc },
    'Claude — ' + (acc === 'mac' ? 'this Mac’s login' : acc) + ' (' + names.join(', ') + ')')));
}

/// The tab, drawn into `host`; reads afresh. `again()` reads and draws it again (after an Allow).
export async function networkTab(name, host) {
  let r;
  try { r = await api('workspace-reach', { method: 'POST', json: { workspace: name } }); } catch (e) {
    host.replaceChildren(callout('bad', { title: 'Its network could not be read', body: e.message || String(e) }));
    return;
  }
  const again = () => networkTab(name, host);
  const sec = (title, ...body) => h('section', { class: 'wsn-sec', 'data-wsn-sec': title }, h('h2', null, title), ...body);
  host.replaceChildren(h('div', { class: 'wsn', 'data-ws-network': name },
    sec('The workspace’s permissions', permissionsTable(r),
      h('p', { class: 'muted' }, 'Allow changes one agent’s permissions; the default for new workers stays as it is (doz workspace edit sets it).')),
    sec('Refused lately', refusedList(r, again)),
    sec('This Mac’s ports', portsBlock(r)),
    sec('Held for agents', heldBlock(r)),
    sec('Accounts used here', accountsBlock(r)),
    r.hidden ? h('p', { class: 'muted', 'data-wsn-hidden': String(r.hidden) }, r.hidden + ' on this Mac not shown to this browser (serve.mac_sessions).') : null,
    h('p', { class: 'wsn-foot muted' }, 'Nothing here shows a secret: a name, where it goes and a fingerprint. The values stay in your keychain.'),
    h('div', { class: 'cando-cmds' }, cmdLine('doz workspace show ' + name + ' --network'))));
}
