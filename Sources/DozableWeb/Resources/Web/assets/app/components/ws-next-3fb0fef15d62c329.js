// components/ws-next — A workspace's one next action in a list (Home's rows, the Workspaces page): the button its state
// offers (Sleep, Wake, Reopen, Restore — its plan's dialog, components/ws-lifecycle.js), a setting-up one's gaps and the
// command that starts it, a started one's room beside.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { refresh } from '../core/router-a64d6adcecdda0a8.js';
import { roomHash } from '../core/routes-0babfc190b1519e4.js';
import { isDone, loadWorkspace, loadWorkspaces } from '../core/workspaces-07036f2cf12d8805.js';
import { LIFECYCLE, primaryVerb } from '../core/ws-lifecycle-88cf439c69606368.js';
import { cmdLine } from './cmd-line-297cfdc0127faef7.js';
import { toast } from './notices-0c2ff2db323bba12.js';
import { lifecycleCommand, lifecycleRefusal, openLifecycle, transitional } from './ws-lifecycle-a3e29b260841ad63.js';

/// `w` a row of the listing; `d` its detail when read (a setting-up one's gaps), else null.
export function wsNext(w, d) {
  const verb = primaryVerb(w.state);
  if (verb && verb !== 'start') {
    const why = lifecycleRefusal(), v = LIFECYCLE[verb];
    const b = h('button', { type: 'button', class: 'btn sm', 'data-home-next': verb, disabled: why || transitional(w.name) ? true : null,
      title: why ? why + ' — ' + lifecycleCommand(verb, w.name) : v.desc,
      on: { click: async () => {
        try { openLifecycle(await loadWorkspace(w.name, 0), verb, async () => { await loadWorkspaces(0).catch(() => null); refresh(false); }); } catch (e) { toast(e.message || String(e), true); }
      } } }, icon(v.icon), v.label);
    return h('div', { class: 'hm-next-acts' }, b, !isDone(w) && w.room ? h('a', { href: roomHash(w.name), class: 'btn sm quiet' }, icon('message-square'), 'Open room') : null);
  }
  if (isDone(w)) return null;
  if (w.state === 'setting-up') {
    const lines = d ? (d.gaps || []).map((g) => g.why).concat(d.notes) : [];
    const gaps = lines.length ? h('ul', { class: 'hm-gaps' }, ...lines.map((n) => h('li', null, n))) : null;
    return h('div', { class: 'hm-start' }, gaps, cmdLine('doz workspace start ' + w.name));
  }
  return w.room ? h('a', { href: roomHash(w.name), class: 'btn sm' }, icon('message-square'), 'Open room') : null;
}
