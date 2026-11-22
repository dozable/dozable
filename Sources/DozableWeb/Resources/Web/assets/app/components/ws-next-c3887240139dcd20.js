// components/ws-next — A workspace's one next action in a list (Home's rows, the Workspaces page): the button its state
// offers (Sleep, Wake, Reopen, Restore — its plan's dialog, components/ws-lifecycle.js), a setting-up one's gaps and the
// command that starts it, a started one's room beside.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { refresh } from '../core/router-1d802f0ab3cd7fc6.js';
import { roomHash } from '../core/routes-c03e6aed84ec9eb3.js';
import { isDone, loadWorkspace, loadWorkspaces } from '../core/workspaces-e4514645964cc09e.js';
import { LIFECYCLE, primaryVerb } from '../core/ws-lifecycle-54187500e950c88c.js';
import { cmdLine } from './cmd-line-caa1b64206f6aed0.js';
import { toast } from './notices-ba28f20ef4c2ccea.js';
import { lifecycleCommand, lifecycleRefusal, openLifecycle, transitional } from './ws-lifecycle-dc56c25e708d88c6.js';

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
