// views/mac-capabilities — "What this session can do" for a session on this Mac (fenced or not): the rows the host computes
// (`MacFence.capabilities` — the CLI prints the same ones; the page never works out its own), the tile's chips (picked by
// the server from those rows: ≤ 4 + "+N"), and the three bridges' switches — the only things changed from here, live.
// Every other row says "at the next start": it is a flag of `doz run @mac`, never a restart from the page with more.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { when } from '../core/format-b2e68384da8d2f36.js';
import { tildeIn } from '../core/paths-074fefdb8b1d48aa.js';
import { permissionSwitches } from '../components/permissions-b54aee277d8012b8.js';

/// The chip word's icon: the fence's own, else a plain mark.
const CHIP_ICON = { fence: 'shield', keychain: 'key-round', 'agent-config': 'folder', github: 'git-fork' };
/// The bridges a person may switch live, and the action's field for each.
export const BRIDGE_FIELD = { 'open-url': 'openURL', 'open-files': 'openFiles', clipboard: 'clipboard' };

/// One chip (`{id, word, tone}`): a word first, colour second (never colour alone).
export function capChip(c) {
  const fenceWord = c.id === 'fence';
  const glyph = fenceWord && /^No isolation|^Guard rail/.test(c.word) ? 'triangle-alert' : CHIP_ICON[c.id] || 'info';
  return h('span', { class: 'cap-chip tone-' + (c.tone || 'info'), 'data-chip': c.id }, icon(glyph), c.word);
}

/// The tile's chips and its "+N" (opens the panel). An older server (no chips) gets the plain No isolation chip.
export function capChips(s, onMore) {
  const chips = Array.isArray(s.chips) && s.chips.length ? s.chips : [{ id: 'fence', word: 'No isolation', tone: 'warn' }];
  const more = s.moreCapabilities > 0
    ? h('button', { type: 'button', class: 'cap-more', 'data-cap-more': '', title: 'What this session can do — every row', 'aria-label': s.moreCapabilities + ' more: what this session can do',
                    on: { click: (ev) => { ev.stopPropagation(); onMore(); } } }, '+' + s.moreCapabilities)
    : null;
  return h('span', { class: 'cap-chips' }, chips.map(capChip), more);
}

/// The marks beside the chips that are news, not a grant: stopped for git, the network waiting for a host, refusals seen.
export function fenceMarks(s, open) {
  const f = s.fence;
  if (!f) return [];
  const out = [];
  if (f.stoppedForGit) out.push(h('button', { type: 'button', class: 'cap-mark tone-bad', 'data-mark': 'stopped', title: 'Its git config changed in a way a fenced session may not — Review, then Resume',
                                              on: { click: (ev) => { ev.stopPropagation(); open('can'); } } }, icon('pause'), 'Stopped: git config'));
  if (s.state === 'running' && f.network === 'waiting (no host)') out.push(h('span', { class: 'cap-mark tone-warn', 'data-mark': 'network', title: 'Its connections wait until a host serves its proxy again (doz host start)' }, icon('hourglass'), 'network waiting'));
  if (f.denialsSeen > 0) out.push(h('button', { type: 'button', class: 'cap-mark tone-info', 'data-mark': 'refusals', title: 'What its fence refused — the Network tab',
                                               on: { click: (ev) => { ev.stopPropagation(); open('network'); } } }, icon('ban'), f.denialsSeen + ' refused'));
  return out;
}

/// The panel. `opts`: `canEdit` (this browser may switch the bridges), `onBridge(field, value)`, `onNetwork()` (the
/// network row's log link), `compact` (the wizard's preview: no controls).
export function capabilitiesPanel(s, opts = {}) {
  const caps = Array.isArray(s.capabilities) ? s.capabilities : [];
  if (!caps.length) return h('div', { class: 'empty' }, 'This session was opened before Dozable said what sessions can do — Restart says it.');
  const f = s.fence;
  const rows = caps.map((c) => {
    const live = c.editable === 'live';
    let extra = null;
    if (c.id === 'clipboard' && f && f.lastCopyAt) extra = h('div', { class: 'cap-note' }, 'last copy ' + when(f.lastCopyAt) + ' — its first characters were in the notice');
    if (c.id === 'network' && opts.onNetwork && s.fenced) {
      extra = h('div', { class: 'cap-note' }, h('a', { href: '#', 'data-cap-log': '', on: { click: (ev) => { ev.preventDefault(); opts.onNetwork(); } } }, 'Its permissions and connection log'),
        c.link ? h('span', { class: 'muted' }, ' · ', h('code', null, c.link)) : null);
    }
    return h('li', { class: 'cap-row' + (s.fenced ? '' : ' is-unfenced'), 'data-cap': c.id },
      h('span', { class: 'cap-name' }, c.name),
      h('span', { class: 'cap-state' }, tildeIn(c.state)),
      h('span', { class: 'cap-sentence' }, tildeIn(c.sentence), extra),
      h('span', { class: 'cap-when' + (live ? ' is-live' : ''), title: live ? 'Changes while it runs' : 'Changes when it starts again (a flag of doz run @mac)' },
        live ? 'live' : 'at the next start'));
  });
  const parts = [h('ul', { class: 'cap-list', 'aria-label': 'What this session can do' }, rows)];
  // The bridges, live — a fenced session's only (an unfenced program opens things itself).
  if (!opts.compact && s.fenced && f) {
    const b = f.bridges || {};
    const on = new Set(Object.entries(BRIDGE_FIELD).filter(([, k]) => b[k]).map(([id]) => id));
    const row = (id) => caps.find((c) => c.id === id) || { name: id, sentence: '' };
    const bridgeRows = Object.keys(BRIDGE_FIELD).map((id) => ({ id, title: row(id).name, summary: tildeIn(row(id).sentence) }));
    parts.push(h('div', { class: 'cap-bridges', 'data-cap-bridges': '' },
      h('div', { class: 'cap-sub' }, h('strong', null, 'Change live'), h('span', { class: 'muted' }, opts.canEdit ? ' — from its next one' : ' — this browser may only watch')),
      permissionSwitches(bridgeRows, on, (id, v) => opts.onBridge && opts.onBridge(BRIDGE_FIELD[id], v), { hosts: false, disabled: !opts.canEdit || !opts.onBridge })));
  }
  if (!opts.compact) {
    parts.push(h('p', { class: 'cap-foot muted' }, s.fenced
      ? 'Everything marked “at the next start” is a flag of doz run @mac (doz run --help) — end the session and open it again with the flags you want.'
      : 'Nothing holds this session: it runs as you. doz run @mac --fenced puts a fence around the next one (New session on this Mac… shows the command).'));
  }
  return h('div', { class: 'cap-panel' + (s.fenced ? ' is-fenced' : ' is-unfenced'), 'data-cap-panel': s.name || '' }, parts);
}
