// components/ws-gaps — What a workspace's start would still refuse (the set-up check's gaps): one line each — why, the
// step of the New workspace wizard that fixes it (a link there, in the wizard), and its command under "Show the command".
// The wizard draws the plan's gaps (`POST /api/v1/workspace-plan`); a workspace's page while it is setting up draws
// `workspace-show`'s (GET /api/v1/workspaces/{w}: `gaps`). Both are looks: nothing is written, the keychain is not read.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { chatOnInline } from './chat-on-9a75307516e1fcf5.js';
import { cmdLine } from './cmd-line-10b1a69c2a5bd0f5.js';

const STEP_WORDS = ['the work', 'who manages', 'where it runs', 'grants & when'];

/// The gaps as a list (`opts.goStep(i)`: a link to that step of the wizard; `opts.steps`: false leaves the step out;
/// `opts.onChatOn`: chat's gap gets an inline "Turn chat on", and this is called once chat is on).
export function gapsList(gaps, opts = {}) {
  return h('ul', { class: 'ws-gaps', 'data-ws-gaps': String(gaps.length) }, ...gaps.map((g) => {
    const step = typeof g.step === 'number' ? g.step - 1 : null;
    const where = opts.goStep && step !== null
      ? h('a', { href: '#', class: 'ws-gap-step', on: { click: (ev) => { ev.preventDefault(); opts.goStep(step); } } }, 'Step ' + (step + 1) + ' · ' + STEP_WORDS[step])
      : null;
    return h('li', { class: 'ws-gap', 'data-gap': g.item },
      h('span', { class: 'ws-gap-why' }, icon('triangle-alert'), g.why),
      g.item === 'chat' && opts.onChatOn ? chatOnInline({ onOn: opts.onChatOn }) : null,
      where,
      h('details', { class: 'ws-gap-fix' }, h('summary', null, 'Show the command'), cmdLine(g.fix)));
  }));
}

/// The panel: "N to set up" with the list, or that nothing is missing.
export function gapsPanel(gaps, opts = {}) {
  const n = gaps.length;
  return h('div', { class: 'ws-gaps-panel' + (n ? '' : ' is-ready'), 'data-ws-gaps-panel': String(n) },
    h('div', { class: 'ws-gaps-head' }, icon(n ? 'list-checks' : 'circle-check'),
      h('b', null, n ? n + ' to set up' : opts.readyText || 'Fully set up — it can start'),
      n && opts.startWords ? h('span', { class: 'muted' }, ' · ' + opts.startWords) : null),
    n ? gapsList(gaps, opts) : null);
}

/// "It can start once: …" — the gaps in a sentence (a disabled Start's title).
export function startsOnce(gaps) {
  return gaps.length ? 'It can start once: ' + gaps.map((g) => g.why).join('; ') : '';
}
