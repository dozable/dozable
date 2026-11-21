// views/ws-folders — A workspace's Folders & points tab (#/w/NAME/folders): its folders (and each agent's own working folder
// not among them) with their rules, what changed in each since the work started — looked at by a bounded walk on this Mac,
// never by running anything in the folder (git included); attributed by folder, never to an agent — and each micro VM
// agent's restore points. Read afresh on every visit (`POST /api/v1/workspace-folders`, one read-only request). Take a
// restore point is `point-take` (a micro VM's); Open in ▾ is `files/open` (this Mac's own browser, a sandbox's shared folder);
// revert, duplicate, template and + Folder are commands to copy.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-575fccc668c266ed.js';
import { full, when } from '../core/format-b2e68384da8d2f36.js';
import { actOrThrow, waitForOp } from '../core/operations-4179844aef9e0eb8.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { isRemote } from '../core/session-cae9e98674cc3e6a.js';
import { callout } from '../components/callout-f30e3ad8767a987a.js';
import { cmdLine } from '../components/cmd-line-77edaf56061d85a4.js';
import { moreMenu } from '../components/menus-b8f822d6b7817c72.js';
import { pageFailure, toast } from '../components/notices-87175599b170575b.js';
import { editorItems, openOnMac } from '../components/open-with-b7477f55ef4a063d.js';

async function takePoint(sandbox, again) {
  try {
    const end = await waitForOp(await actOrThrow({ action: 'point-take', sandbox }), 300);
    if (!end) pageFailure('No answer yet — Operations shows how it ends.');
    else if (end.state === 'done') toast(end.text);
    else pageFailure(end.text || 'No restore point was taken of ' + sandbox);
  } catch (e) { pageFailure(e.message || String(e)); }
  await again();
}

/// Open in ▾ for a folder a sandbox of the workspace shares (its /workspace): the Finder and the editors; any other folder
/// shows `open PATH` to copy.
function openIn(f, sandboxOf) {
  const sb = sandboxOf(f.path);
  if (isRemote()) return null;
  if (!sb) return cmdLine('open ' + f.path);
  const items = [{ label: 'Show in the Finder', icon: 'folder-open', onSelect: () => openOnMac(sb, '/workspace', {}) }, ...editorItems(sb, '/workspace')];
  return moreMenu('Open ' + tildePath(f.path) + ' in', items, { small: true, data: { openIn: f.path } }).el;
}

function folderCard(f, sandboxOf) {
  const rules = [f.ignoreRules != null ? '.dozignore (' + f.ignoreRules + ')' : null, f.readonlyRules != null ? '.dozreadonly (' + f.readonlyRules + ')' : null].filter(Boolean);
  const head = h('div', { class: 'wsf-head' },
    h('span', { class: 'wsf-path', title: f.path }, icon('folder'), tildePath(f.path)),
    h('span', { class: 'ws-chip' }, f.mode), f.main ? h('span', { class: 'ws-chip' }, 'main') : null,
    f.workspace ? null : h('span', { class: 'ws-chip' }, 'an agent’s own'),
    rules.length ? h('span', { class: 'muted' }, 'rules: ' + rules.join(' · ')) : null,
    h('span', { class: 'ws-sp' }), openIn(f, sandboxOf));
  let body;
  if (!f.exists) body = callout('warn', { compact: true, body: 'Not there, or not a folder this Mac reads without following a link.' });
  else if (f.hidden) body = h('p', { class: 'muted' }, 'Its changes are not shown to this browser: only sessions on this Mac work in it (serve.mac_sessions).');
  else if (!f.changes.length) body = h('p', { class: 'muted', 'data-wsf-none': '' }, 'Nothing changed since the start.');
  else {
    body = h('ul', { class: 'wsf-changes', 'data-wsf-count': String(f.count) }, ...f.changes.map((c) => h('li', { 'data-change': c.path },
      h('span', { class: 'wsf-kind', 'data-kind': c.kind, title: c.kind === 'A' ? 'new since the start' : 'changed since the start' }, c.kind), h('code', null, c.path))));
  }
  return h('div', { class: 'panel wsf-folder', 'data-wsf-folder': f.path }, head,
    h('div', { class: 'wsf-sub muted' }, (f.exists && !f.hidden ? 'Changed since the start (' + f.count + (f.truncated ? '+' : '') + ')' : ''),
      f.agents.length ? ' · works here: ' + f.agents.join(', ') : ''),
    body,
    f.truncated ? h('p', { class: 'muted', 'data-wsf-truncated': '' }, 'Cut short: the newest ' + f.changes.length + ' of what ' + f.scanned + ' entries showed — a big folder is looked at only up to its limits.') : null);
}

function pointsBlock(d, again) {
  if (!d.points.length) return h('p', { class: 'muted' }, 'None: a restore point is per micro VM agent (its disk). Agents on this Mac work straight in your folders.');
  return h('div', { class: 'wsf-points' }, ...d.points.map((p) => h('div', { class: 'panel wsf-point', 'data-wsf-points': p.sandbox },
    h('div', { class: 'wsf-head' }, h('b', null, p.agent), h('span', { class: 'muted' }, ' · ' + p.sandbox), h('span', { class: 'ws-sp' }),
      h('button', { type: 'button', class: 'btn sm', 'data-take-point': p.sandbox, on: { click: () => takePoint(p.sandbox, again) } }, icon('camera'), 'Take a restore point')),
    p.rows.length ? h('ul', { class: 'wsf-point-rows' }, ...p.rows.map((r) => h('li', { 'data-point': r.name },
      h('span', { title: full(r.createdAt) }, when(r.createdAt)), ' ', h('b', null, r.name), r.automatic ? h('span', { class: 'muted' }, ' (auto)') : null,
      r.note ? h('span', { class: 'muted' }, ' — ' + r.note) : null)))
      : h('p', { class: 'muted' }, 'None yet.'),
    h('div', { class: 'wsf-cmds' }, cmdLine('doz point revert ' + p.sandbox + ' POINT'), cmdLine('doz duplicate ' + p.sandbox + ' NEW --point POINT'),
      h('a', { href: '#/sandbox/' + p.sandbox, class: 'muted' }, 'Its Points tab')))));
}

/// The tab, drawn into `host`; reads afresh. `detail` is the workspace's (`workspace-show`): which sandbox shares a folder.
export async function foldersTab(name, host, detail) {
  let d;
  try { d = await api('workspace-folders', { method: 'POST', json: { workspace: name } }); } catch (e) {
    host.replaceChildren(callout('bad', { title: 'Its folders could not be read', body: e.message || String(e) }));
    return;
  }
  const again = () => foldersTab(name, host, detail);
  // A folder is a sandbox's /workspace when that sandbox's agent works in it (the walk's attribution, by folder).
  const sandboxOf = (path) => {
    const f = d.folders.find((x) => x.path === path);
    const a = f && detail ? detail.agents.find((x) => x.kind === 'sandbox' && f.agents.includes(x.name)) : null;
    return a ? a.sandbox : null;
  };
  const sec = (title, ...body) => h('section', { class: 'wsn-sec', 'data-wsf-sec': title }, h('h2', null, title), ...body);
  host.replaceChildren(h('div', { class: 'wsf', 'data-ws-folders': name },
    sec('Folders', ...(d.folders.length ? d.folders.map((f) => folderCard(f, sandboxOf)) : [h('p', { class: 'muted' }, 'No folders: a workspace may work on none.')]),
      h('div', { class: 'wsf-add' }, h('button', { type: 'button', class: 'btn sm', disabled: true, title: 'Copy the command: doz workspace edit ' + name + ' --add-folder DIR' },
        icon('plus'), 'Folder'), cmdLine('doz workspace edit ' + name + ' --add-folder DIR'))),
    h('p', { class: 'muted wsf-honest', 'data-wsf-honest': '' }, 'Changed since ' + full(d.since) + ', by file times — looked at without running anything in the folder. ',
      'It says which folder changed, never which agent changed it; a deletion is not seen.'),
    sec('Restore points', pointsBlock(d, again)),
    h('div', { class: 'cando-cmds' }, cmdLine('doz workspace show ' + name + ' --folders'))));
}
