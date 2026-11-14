// views/mac-wizard — "New session on this Mac…": the five owner-approved cases, each with what it opens; the exact
// `doz run @mac` command the host builds from the choices (`POST mac/session-plan`) with Copy, and Open in Terminal ONLY
// for a plainly fenced shape (a fenced case, neither of Swift's toggles, the agent's config private) — the person's own
// terminal app runs it; nothing here starts a session in the host. The Mac's own browser only (the server refuses the
// route to another computer). The later cases are flags of the CLI today; their cards come later.
import { h } from '../dom/h.js';
import { icon, withIcon } from '../dom/icons.js';
import { api } from '../core/api.js';
import { setting } from '../core/settings.js';
import { tildePath } from '../core/paths.js';
import { choiceCard } from '../components/choice.js';
import { toast } from '../components/notices.js';
import { capabilitiesPanel } from './mac-capabilities.js';

/// The cases, in the order the owner gave them a meaning (fenced first, then the two that open everything).
export const MAC_CASES = [
  { id: 'plain', title: 'Plain agent', icon: 'shield', fenced: true,
    line: 'An agent on one folder: its own temp and caches, your Keychain closed, the network through Dozable’s proxy.' },
  { id: 'web', title: 'Web / Node development', icon: 'code-xml', fenced: true,
    line: 'The same fence, and the ports of your dev server — it may listen on them, your browser and tests reach them. Node uses the proxy by itself (NODE_USE_ENV_PROXY=1).' },
  { id: 'xcode', title: 'Swift / Xcode development', icon: 'wrench', fenced: true,
    line: 'The fence with Xcode’s build services: builds into the session’s own DerivedData (xcodebuild -derivedDataPath "$DOZ_DERIVED"); SwiftPM runs with --disable-sandbox (its own sandbox cannot nest).' },
  { id: 'signing', title: 'Signing & notarisation', icon: 'badge-check', fenced: false,
    line: 'No fence: Apple’s signing and notary tools need your Keychain and their own networking. It runs as you.' },
  { id: 'unfenced', title: 'Unfenced', icon: 'triangle-alert', fenced: false,
    line: 'No isolation at all — your files, Keychain and network, as if you typed it yourself.' },
];
/// Possible later cards (the flags work in the CLI now).
const LATER = [
  ['Two repositories at once', '--write DIR', 'reads and writes one more folder'],
  ['Git over ssh with your keys', '--ssh-agent', 'your SSH agent: list and sign only'],
  ['A locked-down research session', '--permissions locked', 'its model’s hosts only'],
];

function seg(name, value, choices, onChange) {
  const box = h('div', { class: 'segmented', role: 'group', 'aria-label': name, 'data-wiz-seg': name });
  const paint = () => { for (const b of box.children) { const on = b.dataset.value === value; b.classList.toggle('active', on); b.setAttribute('aria-pressed', on ? 'true' : 'false'); } };
  for (const [v, label, ic] of choices) {
    box.append(h('button', { type: 'button', class: 'seg', 'data-value': v, on: { click: () => { value = v; paint(); onChange(v); } } }, ic ? withIcon(ic, label) : label));
  }
  paint();
  return box;
}

/// Open the wizard. `defaults`: `{workdir}` (a folder to start from).
export function openMacWizard(defaults = {}) {
  const f = { kind: 'plain', program: 'claude', workdir: defaults.workdir || '', session: '', agentConfig: setting('mac.agent_config', 'private') === 'shared' ? 'shared' : 'private',
              github: 'off', ports: '3000', simulator: false, keychain: false };
  const d = h('dialog', { class: 'dlg mac-wizard', 'aria-label': 'New session on this Mac' });
  const cards = h('fieldset', { class: 'wiz-choices mac-cases' }, h('legend', null, 'What is it for?'));
  for (const c of MAC_CASES) {
    const input = h('input', { type: 'radio', name: 'mac-case', value: c.id });
    input.checked = c.id === f.kind;
    input.addEventListener('change', () => { if (input.checked) { f.kind = c.id; paintOptions(); plan(); } });
    cards.append(choiceCard({ class: 'wiz-choice mac-case', 'data-case': c.id }, input,
      h('div', { class: 'mac-case-text' },
        h('div', { class: 'mac-case-title' }, icon(c.icon), h('strong', null, c.title),
          h('span', { class: 'tag ' + (c.fenced ? 'ok' : 'warn') }, c.fenced ? 'Fenced' : 'No fence')),
        h('div', { class: 'muted' }, c.line))));
  }
  cards.append(h('details', { class: 'mac-later' }, h('summary', null, 'More, with the command line for now'),
    h('ul', null, LATER.map(([t, flag, what]) => h('li', null, h('strong', null, t), ' — ', h('code', null, flag), ' ', h('span', { class: 'muted' }, what))))));

  const opts = h('div', { class: 'mac-options' });
  const commandBox = h('code', { class: 'mac-command', 'data-mac-command': '' }, '…');
  const why = h('div', { class: 'mac-why muted', 'data-copy-only': '' });
  const err = h('div', { class: 'dlg-error', role: 'alert' });
  const preview = h('div', { class: 'mac-preview', 'data-mac-preview': '' });
  const facts = h('div', { class: 'mac-facts', 'data-mac-facts': '' });
  let last = null;
  const copyBtn = h('button', { type: 'button', class: 'btn', 'data-mac-copy': '', on: { click: async () => {
    if (!last) return;
    try { await navigator.clipboard.writeText(last.command); toast('Copied — paste it in a terminal on this Mac'); }
    catch (_) { err.textContent = 'This browser would not copy — select the command and copy it yourself.'; }
  } } }, withIcon('copy', 'Copy'));
  const openBtn = h('button', { type: 'button', class: 'btn primary', 'data-mac-open': '', on: { click: async () => {
    if (!last || !last.openable) return;
    openBtn.disabled = true;
    try { const r = await api('mac/session-plan', { method: 'POST', json: body(true) }); toast(r.opened || 'Terminal opened'); d.close(); }
    catch (e) { err.textContent = e.message || String(e); openBtn.disabled = false; }
  } } }, withIcon('square-terminal', 'Open in Terminal'));

  function body(open) {
    const b = { case: f.kind, program: f.program, workdir: f.workdir };
    if (f.session) b.session = f.session;
    const fenced = MAC_CASES.find((c) => c.id === f.kind).fenced;
    if (fenced) {
      if (f.program === 'claude') b.agentConfig = f.agentConfig;
      if (f.github !== 'off') b.github = f.github;
    }
    if (f.kind === 'web') b.ports = f.ports.split(/[\s,]+/).filter(Boolean).map(Number);
    if (f.kind === 'xcode') { b.simulator = f.simulator; b.keychain = f.keychain; }
    if (open) b.open = true;
    return b;
  }
  function field(label, input, help) { return h('label', { class: 'field' }, h('span', null, label), input, help ? h('small', null, help) : null); }
  function text(key, placeholder) {
    const i = h('input', { type: 'text', spellcheck: 'false', autocomplete: 'off', placeholder, 'data-mac-field': key });
    i.value = f[key];
    i.addEventListener('input', () => { f[key] = i.value.trim(); plan(); });
    return i;
  }
  function toggle(key, label, help) {
    const i = h('input', { type: 'checkbox', role: 'switch', 'data-mac-toggle': key });
    i.checked = f[key];
    i.addEventListener('change', () => { f[key] = i.checked; plan(); });
    return h('label', { class: 'field check mac-toggle' }, i, h('span', null, h('strong', null, label), h('small', null, help)));
  }
  function paintOptions() {
    const c = MAC_CASES.find((x) => x.id === f.kind);
    const rows = [
      field('Program', seg('program', f.program, [['claude', 'Claude Code', 'terminal'], ['shell', 'Login shell', 'square-terminal']], (v) => { f.program = v; paintOptions(); plan(); })),
      field('Folder', text('workdir', '/Users/you/src/app'), c.fenced ? 'It reads and writes this folder only (never your home itself).' : 'Where it starts.'),
      field('Session name', text('session', f.program === 'claude' ? 'claude' : 'shell'), 'Optional — 1–32 of letters, digits . _ -'),
    ];
    if (c.fenced && f.program === 'claude') {
      rows.push(field('Agent settings', seg('agentConfig', f.agentConfig, [['private', 'Private'], ['shared', 'Shared — less isolated']], (v) => { f.agentConfig = v; plan(); }),
        'Private: its own Claude settings folder (your instructions and skills read-only). Shared: your own ~/.claude — what it writes there runs in your next unfenced Claude Code.'));
    }
    if (c.fenced) rows.push(field('GitHub as you', seg('github', f.github, [['off', 'Off'], ['read', 'Read'], ['push', 'Push']], (v) => { f.github = v; plan(); }),
      'Read: clone and read your repositories; pushes refused. The token never enters the session.'));
    if (f.kind === 'web') rows.push(field('Ports', text('ports', '3000'), 'Your dev server’s — it may listen on these and nothing else of this Mac’s (comma-separated, at most 8).'));
    if (f.kind === 'xcode') {
      rows.push(toggle('simulator', 'Run in the Simulator', 'Opens LaunchServices and the Simulator — what they launch runs OUTSIDE the fence: a guard rail, not a boundary.'),
        toggle('keychain', 'Sign with my Apple identity', 'Opens your Keychain to it — signing works, and so could reading your saved logins.'));
    }
    opts.replaceChildren(...rows);
  }
  let timer = null, seq = 0;
  function plan() {
    clearTimeout(timer);
    timer = setTimeout(async () => {
      const n = ++seq;
      err.textContent = '';
      if (!f.workdir.startsWith('/')) {
        last = null;
        commandBox.textContent = 'doz run @mac …';
        why.textContent = 'Name the folder (an absolute path, like /Users/you/src/app) to see the command.';
        openBtn.disabled = true; copyBtn.disabled = true;
        preview.replaceChildren();
        facts.replaceChildren();
        return;
      }
      try {
        const p = await api('mac/session-plan', { method: 'POST', json: body(false) });
        if (n !== seq) return;
        last = p;
        commandBox.textContent = p.command;
        copyBtn.disabled = false;
        openBtn.disabled = !p.openable;
        openBtn.title = p.openable ? 'Opens a terminal on this Mac that runs it' : 'Copy only: ' + (p.copyOnly || '');
        why.textContent = p.openable ? 'Open in Terminal runs it in your default terminal app; Copy to run it yourself.' : 'Copy only — ' + (p.copyOnly || '');
        facts.replaceChildren(
          h('span', { class: 'chip-kv', 'data-fact': 'config' }, h('span', { class: 'k' }, 'Agent settings'), p.agentConfig ? (p.agentConfig === 'shared' ? 'shared (less isolated)' : 'private') : 'none'),
          h('span', { class: 'chip-kv', 'data-fact': 'history' }, h('span', { class: 'k' }, 'History'), p.history || 'none'),
          h('span', { class: 'chip-kv', 'data-fact': 'folder' }, h('span', { class: 'k' }, 'Folder'), tildePath(f.workdir)));
        preview.replaceChildren(h('div', { class: 'cap-sub' }, h('strong', null, 'What it could do'), h('span', { class: 'muted' }, ' — what doz run @mac … --dry-run says')),
          capabilitiesPanel({ name: 'plan', fenced: p.fenced, capabilities: p.capabilities }, { compact: true }));
      } catch (e) {
        if (n !== seq) return;
        last = null;
        openBtn.disabled = true; copyBtn.disabled = true;
        err.textContent = e.message || String(e);
      }
    }, 150);
  }
  const close = h('button', { type: 'button', class: 'btn sm quiet icon-only', title: 'Close', 'aria-label': 'Close', on: { click: () => d.close() } }, icon('x'));
  d.append(h('form', { method: 'dialog', on: { submit: (ev) => ev.preventDefault() } },
    h('div', { class: 'dlg-head' }, h('h2', { class: 'h-title' }, 'New session on this Mac'), close),
    h('div', { class: 'dlg-body mac-wizard-body' },
      h('p', { class: 'sub' }, 'Choose what it is for — each card says what it opens. Dozable shows the exact command; it never starts a session for you from here.'),
      h('div', { class: 'mac-wizard-grid' }, cards, h('div', { class: 'mac-wizard-side' }, opts, facts)),
      h('div', { class: 'mac-command-box' }, h('div', { class: 'cap-sub' }, h('strong', null, 'The command')), commandBox, why),
      err, preview),
    h('div', { class: 'dlg-foot dlg-buttons' }, h('span', { class: 'why' }), copyBtn, openBtn)));
  d.addEventListener('close', () => d.remove());
  document.body.append(d);
  paintOptions();
  plan();
  d.showModal();
  return d;
}
