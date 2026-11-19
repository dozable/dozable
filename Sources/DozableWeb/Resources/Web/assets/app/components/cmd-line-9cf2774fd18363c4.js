// components/cmd-line — A command a person may type in a terminal on this Mac, shown with a Copy button.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { pageFailure, toast } from './notices-74c31f481efe72bc.js';

export function cmdLine(text, opts = {}) {
  const copy = h('button', { type: 'button', class: 'btn sm quiet icon-only', title: 'Copy the command', 'aria-label': 'Copy: ' + text,
    on: { click: async () => {
      try { await navigator.clipboard.writeText(text); toast('Copied — paste it in a terminal on this Mac'); } catch (_) { pageFailure('This browser could not copy — ' + text); }
    } } }, icon('copy'));
  return h('span', { class: 'cmd-copy' + (opts.cls ? ' ' + opts.cls : ''), 'data-cmd': text }, h('code', null, text), copy);
}
