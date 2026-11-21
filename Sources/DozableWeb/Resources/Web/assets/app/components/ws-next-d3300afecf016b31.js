// components/ws-next — A workspace's one next action in a list (Home's rows, the Workspaces page): the button its state
// offers (Sleep, Wake, Reopen, Restore — its plan's dialog, components/ws-lifecycle.js), a setting-up one's gaps and the
// command that starts it, a started one's room beside.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { refresh } from '../core/router-27408a5c2e927a57.js';
import { roomHash } from '../core/routes-9e8c2eeae9c6e070.js';
import { isDone, loadWorkspace, loadWorkspaces } from '../core/workspaces-66f036b194c772cf.js';
import { LIFECYCLE, primaryVerb } from '../core/ws-lifecycle-54187500e950c88c.js';
import { cmdLine } from './cmd-line-be6be849d82e80b8.js';
import { toast } from './notices-616063aab869afff.js';
import { lifecycleCommand, lifecycleRefusal, openLifecycle, transitional } from './ws-lifecycle-4bfc5bc84c8f8bb6.js';

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
