// core/ws-activity — A workspace's Activity tab, its pure part: the log's lines (pages of `workspace-log`, newest first)
// and the operations this dashboard started for its agents (`/api/v1/operations`: the last 50, filtered here by the
// workspace's places — `WorkspaceRow.places` — and its name) merged into one list, newest first, and filtered: All · You ·
// Agents · Lifecycle · Network. Imports nothing (WebModulesTests runs it in JavaScriptCore).

export const ACTIVITY_FILTERS = [
  { id: 'all', label: 'All' },
  { id: 'you', label: 'You' },
  { id: 'agents', label: 'Agents' },
  { id: 'lifecycle', label: 'Lifecycle' },
  { id: 'network', label: 'Network' },
];

const LIFECYCLE_LOG = new Set(['created', 'kicked-off', 'manager-started', 'manager-stopped', 'slept', 'woke', 'agent-slept', 'agent-woke', 'finished',
  'reopened', 'archived', 'restored', 'room-archived', 'room-unarchived']);
const LIFECYCLE_OPS = /^(workspace-(start|stop|sleep|wake|finish|reopen|archive|restore|delete)|start|wake|sleep|hibernate|shutdown|pause|resume|session-restart|session-end|mac-session-(end|restart|resume))$/;
const NETWORK_OPS = /^(net-policy|mac-net-policy)$/;

/// Whether an operation of the ring is about this workspace: its sandbox is one of the places, its label names one of
/// the sessions on this Mac among the places ("… session S on this Mac"), or its label names the workspace (its own actions).
export function opIsFor(op, workspace, places) {
  const ps = places || [];
  if (op.sandbox && ps.includes(op.sandbox)) return true;
  const label = op.label || '';
  for (const p of ps) {
    if (p.startsWith('@mac/') && label.includes('session ' + p.slice(5) + ' on this Mac')) return true;
  }
  return new RegExp('(^|\\s)' + workspace.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '($|\\s)').test(label) && /^(workspace-|worker-)/.test(op.action || '');
}

/// The merged list: [{kind: 'log'|'op', at (ms), by: 'you'|'doz', text, action, agent?, state?, groups: Set}] newest first.
/// `lines`: the log's lines; `ops`: the operations ring; `filter`: one of ACTIVITY_FILTERS' ids.
export function mergeActivity(lines, ops, workspace, places, filter) {
  const out = [];
  for (const l of lines || []) {
    const groups = ['all'];
    if (l.by === 'you') groups.push('you');
    if (l.agent) groups.push('agents');
    if (LIFECYCLE_LOG.has(l.action)) groups.push('lifecycle');
    out.push({ kind: 'log', at: new Date(l.at).getTime(), by: l.by, text: l.text, action: l.action, agent: l.agent || null, groups });
  }
  for (const o of ops || []) {
    if (!opIsFor(o, workspace, places)) continue;
    const groups = ['all', 'you'];
    if (LIFECYCLE_OPS.test(o.action || '')) groups.push('lifecycle');
    if (NETWORK_OPS.test(o.action || '')) groups.push('network');
    if (/^(worker-|workspace-(adopt|release))/.test(o.action || '')) groups.push('agents');
    out.push({ kind: 'op', at: new Date(o.startedAt).getTime(), by: 'you', text: o.label + (o.text ? ' — ' + o.text : ''), action: o.action,
      state: o.state, id: o.id, groups });
  }
  const f = filter || 'all';
  return out.filter((x) => x.groups.includes(f)).sort((a, b) => b.at - a.at || (a.kind === b.kind ? 0 : a.kind === 'op' ? -1 : 1));
}
