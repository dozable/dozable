// components/bot-form — An Agent / Bot's edit tabs (#/bots/NAME/identity | runs | reached | instructions | account) and a new
// one's form (#/bots/~new, the same sections). Each Save is ONE action, exactly the CLI's: `bot-set` (doz bot set NAME …)
// with only what changed on that tab, or `bot-new` (doz bot new NAME --agent A --isolation I …). Only this Mac's own browser
// changes a bot (the server refuses another computer, `mac-only`); every change is `heldOnly` — no token ever reaches a
// browser, so a bot elsewhere is made or moved only in a terminal: its choice is drawn disabled with the command to copy.
// "unfenced" is never preselected (it acts as you). The instructions are at most INSTRUCTIONS_MAX_BYTES here (the actions'
// 16 KiB body); beyond it, the file command.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { AGENTS } from '../core/agents-b5713528d20be964.js';
import { actOrThrow, waitForOp } from '../core/operations-03041bf9d59d2862.js';
import { isRemote } from '../core/session-ac3b294ded6521bf.js';
import { state } from '../core/state-f551ebce9066b2c8.js';
import { callout } from './callout-a906e34ef11cba9d.js';
import { cmdLine } from './cmd-line-adc8d3a1a3dcde29.js';
import { programName } from './ws-panel-0ee2ec42580be842.js';

/// Why this browser may not change a bot (null: it may) — only this Mac's own browser does.
export const BOT_REMOTE = 'Only from this Mac’s own browser';
export function botChangeRefusal() { return isRemote() ? BOT_REMOTE : null; }
/// The instructions a page may send (the JSON body stays within the actions' 16 KiB).
export const INSTRUCTIONS_MAX_BYTES = 15 * 1024;
/// How a bot elsewhere is made: in a terminal on this Mac, its token written to a file (never shown in a browser).
export function elsewhereCommand(name, agent) {
  return 'doz bot new ' + (name || 'far') + ' --agent ' + (agent || 'codex') + ' --isolation elsewhere --to-file ~/' + (name || 'far') + '.token';
}
export const ISOLATION_WORDS = { vm: 'Sandbox', fenced: 'fenced on this Mac', unfenced: 'unfenced on this Mac — acts as you', elsewhere: 'elsewhere' };
export const REACHED_WORDS = { inbox: 'inbox', poll: 'poll (dozchat)', webhook: 'webhook' };
/// The sections, in the tab row's order (the edit tabs; Roles & ceiling is read only).
export const SECTIONS = [['identity', 'Identity'], ['runs', 'How it runs'], ['reached', 'Reached by'], ['instructions', 'Instructions'], ['account', 'Account']];

const utf8Bytes = (s) => new TextEncoder().encode(s).length;
const skillsOf = (s) => String(s || '').split(',').map((x) => x.trim()).filter(Boolean);

function radios(name, choices, value, onChange) {
  return h('div', { class: 'bf-radios', role: 'radiogroup' }, ...choices.map((c) => {
    const input = h('input', { type: 'radio', name, value: c.value, disabled: c.disabled || null, 'data-bf-choice': name + ':' + c.value });
    input.checked = c.value === value;
    input.addEventListener('change', () => { if (input.checked) onChange(c.value); });
    return h('label', { class: 'bf-radio' + (c.disabled ? ' is-disabled' : ''), title: c.why || null }, input,
      h('span', { class: 'bf-radio-text' }, h('b', null, c.label), c.note ? h('small', null, c.note) : null, c.extra || null));
  }));
}

/// The form: {el, save(), values} — `bot` the detail (null for a new one), `tab` the section shown (a new bot shows every
/// section), `accounts` the store's accounts (names), `readOnly` (another computer, a retired bot), `seed` (Duplicate: a
/// bot's detail filling a new one — never its name, never "elsewhere").
export function botForm({ bot, tab, accounts, readOnly, seed }) {
  const isNew = !bot;
  const s = bot || seed || null;
  const v = {
    name: '', avatar: s && s.avatar || '', agent: s && AGENTS.some(([a]) => a === s.agent) ? s.agent : 'claude-code', model: s && s.model || '',
    // A new bot is fenced unless picked otherwise — a duplicate keeps vm, never unfenced or elsewhere (each only when picked).
    isolation: bot ? bot.isolation : seed && seed.isolation === 'vm' ? 'vm' : 'fenced', deliver: s ? s.deliver : 'poll',
    webhookEntry: s && s.webhookEntry || '', session: s && s.session || '', skills: s ? s.skills.join(', ') : '',
    instructions: s && s.instructions || '', account: s && s.account || '',
  };
  const was = { ...v };
  const form = { dirty: false, key: bot ? bot.name + '/' + tab : '~new' };
  state.botForm = form;
  const err = h('div', { class: 'dlg-error bf-error', role: 'alert', 'data-bf-error': '' });
  const done = h('div', { class: 'bf-done', role: 'status', 'data-bf-done': '' });
  const changed = () => { form.dirty = Object.keys(v).some((k) => v[k] !== was[k]); paintNotes(); };
  const field = (label, input, help) => h('label', { class: 'field' }, h('span', null, label), input, help ? h('small', null, help) : null);
  const text = (k, attrs = {}) => {
    const i = h('input', { type: 'text', name: k, autocomplete: 'off', spellcheck: 'false', disabled: readOnly || attrs.disabled || null, 'data-bf': k, ...attrs });
    i.value = v[k];
    i.addEventListener('input', () => { v[k] = i.value; changed(); });
    return i;
  };
  const select = (k, options) => {
    const s = h('select', { name: k, disabled: readOnly || null, 'data-bf': k }, ...options.map(([val, label]) => {
      const o = h('option', { value: val }, label);
      if (val === v[k]) o.selected = true;
      return o;
    }));
    s.addEventListener('change', () => { v[k] = s.value; changed(); repaint(); });
    return s;
  };

  // Identity
  const identity = () => h('section', { class: 'bf-section', 'data-bf-section': 'identity' },
    isNew ? field('Bot name', text('name', { placeholder: 'mira', maxlength: 40 }),
      'A lower-case letter, then lower-case letters, digits and -. It is its name in chat for good: a retired name is never used again.')
      : h('p', { class: 'muted' }, 'Its name in every room is ' + bot.name + ' — names are chat identities and are not renamed (retire it and make a new one).'),
    field('Avatar', text('avatar', { placeholder: 'a letter, a short text or an emoji', maxlength: 64 })),
    isNew ? field('Agent program', select('agent', AGENTS.filter(([a]) => a !== 'none').map(([a, l]) => [a, l])))
      : h('p', { class: 'muted' }, 'Agent program: ' + programName(bot.agent) + ' (fixed for an identity).'),
    field('Model', text('model', { placeholder: 'its default', maxlength: 120 }), 'Empty: the agent program’s default.'));

  // How it runs
  const runs = () => {
    const fromElsewhere = !isNew && bot.isolation === 'elsewhere';
    const moveCmd = (to) => 'doz bot set ' + bot.name + ' --isolation ' + to;
    const choices = [
      { value: 'vm', label: 'Sandbox', note: 'A Sandbox of its own: no way out but the proxy.' },
      { value: 'fenced', label: 'fenced on this Mac', note: 'A session on this Mac behind the fence: proxy, placeholders, guard.' },
      { value: 'unfenced', label: 'unfenced on this Mac — acts as you', note: 'No proxy, no placeholders, no guard. Only when you pick it.' },
      { value: 'elsewhere', label: 'elsewhere', disabled: true, why: 'Made in a terminal on this Mac: its token is shown once there, never in a browser',
        note: 'Another machine runs it with its own token — given in a terminal on this Mac, never here:',
        extra: cmdLine(isNew ? elsewhereCommand(v.name || null, v.agent === 'claude-code' ? 'claude-code' : v.agent) : 'doz bot set ' + bot.name + ' --isolation elsewhere --to-file ~/' + bot.name + '.token', { cls: 'bf-elsewhere' }) },
    ];
    if (fromElsewhere) for (const c of choices) if (c.value !== 'elsewhere') { c.disabled = true; c.why = 'A move to this Mac makes a new token: in a terminal'; c.extra = cmdLine(moveCmd(c.value)); }
    if (readOnly) for (const c of choices) c.disabled = true;
    const ceiling = bot && bot.ceiling ? ISOLATION_WORDS[bot.ceiling] || bot.ceiling : 'none set';
    return h('section', { class: 'bf-section', 'data-bf-section': 'runs' },
      // 782: inbox reaches only an unfenced session — moving away from unfenced moves its reach to poll.
      radios('isolation', choices, v.isolation, (x) => { v.isolation = x; if (x !== 'unfenced' && v.deliver === 'inbox') v.deliver = 'poll'; changed(); repaint(); }),
      v.isolation === 'unfenced' ? callout('warn', { compact: true, title: 'Acts as you', body: 'Unfenced, it runs as you on this Mac — with your files, keys and network. Pick fenced unless it needs what the fence keeps out.' }) : null,
      h('p', { class: 'muted', 'data-bf-ceiling': '' }, 'Ceiling — the widest a workspace may make it: ' + ceiling + ' (read only: it comes with permissions).'));
  };

  // Reached by
  const reached = () => {
    const claude = (isNew ? v.agent : bot.agent) === 'claude-code' || (bot && bot.kind === 'claude-session');
    const name = isNew ? (v.name || 'NAME') : bot.name;
    return h('section', { class: 'bf-section', 'data-bf-section': 'reached' },
      radios('deliver', [
        // 782: inbox only for an unfenced Claude Code bot — a Sandbox or fenced bot polls (it could never manage otherwise).
        { value: 'inbox', label: 'inbox', note: 'Written into its Claude Code session, busy or idle.', disabled: readOnly || !claude || (v.isolation !== 'unfenced' && v.deliver !== 'inbox'),
          why: !claude ? 'Inbox is for a Claude Code bot' : v.isolation !== 'unfenced' ? 'Inbox reaches only a session run unfenced: a Sandbox or fenced bot polls' : null },
        { value: 'poll', label: 'poll', note: 'It collects its messages with dozchat listen.', disabled: readOnly },
        { value: 'webhook', label: 'webhook', note: 'Called at an entry kept in your keychain.', disabled: readOnly },
      ], v.deliver, (x) => { v.deliver = x; changed(); repaint(); }),
      v.deliver === 'inbox' && v.isolation !== 'unfenced'
        ? callout('warn', { compact: true, body: 'Fenced or in a Sandbox it cannot be reached by inbox (an inbox reaches a session run without a fence): reach it by poll.' }) : null,
      v.deliver === 'inbox' ? field('Its session on this Mac', text('session', { placeholder: name, maxlength: 32 }), 'Empty: a session of its own name.') : null,
      v.deliver === 'webhook' ? field('Its webhook entry', text('webhookEntry', { placeholder: name, maxlength: 40 }), 'Empty: an entry of its own name.') : null,
      v.deliver === 'webhook' ? h('p', { class: 'muted' }, 'Set its entry next in a terminal: ', cmdLine('doz chat webhook set ' + (v.webhookEntry || name))) : null);
  };

  // Instructions (and skills)
  const instructions = () => {
    const area = h('textarea', { name: 'instructions', rows: 10, spellcheck: 'true', disabled: readOnly || null, 'data-bf': 'instructions' });
    area.value = v.instructions;
    const count = h('small', { class: 'bf-count', 'data-bf-count': '' });
    const paint = () => {
      const n = utf8Bytes(v.instructions), over = n > INSTRUCTIONS_MAX_BYTES;
      count.replaceChildren(Math.ceil(n / 102.4) / 10 + ' of ' + INSTRUCTIONS_MAX_BYTES / 1024 + ' KiB',
        over ? h('span', { class: 'bf-over' }, ' — too long for this page: ', cmdLine('doz bot set ' + (isNew ? v.name || 'NAME' : bot.name) + ' --instructions-file F')) : '');
      count.classList.toggle('is-over', over);
    };
    area.addEventListener('input', () => { v.instructions = area.value; changed(); paint(); });
    paint();
    return h('section', { class: 'bf-section', 'data-bf-section': 'instructions' },
      field('Standing instructions', area, 'Your words, given to each of its sessions when it starts — a change applies from its next session.'), count,
      field('Skills', text('skills', { placeholder: 'chat-manager, …' }), 'Comma-separated skills’ names.'));
  };

  // Account
  const account = () => h('section', { class: 'bf-section', 'data-bf-section': 'account' },
    field('Its account', select('account', [['', 'the default'], ['mac', 'this Mac’s Claude Code login'], ...accounts.filter((a) => a !== 'mac').map((a) => [a, a])])),
    h('p', { class: 'muted' }, 'No silent fallback: a missing or signed-out account is said, never replaced by another.'));

  const builders = { identity, runs, reached, instructions, account };
  const notes = h('div', { class: 'bf-notes' });
  const sections = h('div', { class: 'bf-sections' });
  const runningIn = bot ? [bot.running, bot.worksIn].filter(Boolean) : [];
  function paintNotes() {
    const touched = !isNew && ['instructions', 'model', 'account'].some((k) => v[k] !== was[k]);
    notes.replaceChildren(...runningIn.map((w) => callout(touched ? 'warn' : 'info', { compact: true, attrs: { 'data-bf-running': w },
      body: bot.name + ' runs in ' + w + ': name and avatar change now; instructions, model and account apply from its next session. ' + w + '’s room is told.' })));
  }
  function repaint() {
    const shown = isNew ? SECTIONS.map(([k]) => k) : [tab];
    sections.replaceChildren(...shown.map((k) => {
      const title = (SECTIONS.find(([s]) => s === k) || [k, k])[1];
      return h('div', { class: 'bf-group' }, isNew ? h('h3', { class: 'bf-title' }, title) : null, builders[k]());
    }));
  }
  repaint();
  paintNotes();

  /// The body of the one action: a new bot's every field; an edit, only what changed on this tab.
  function body() {
    if (isNew) {
      const b = { action: 'bot-new', name: v.name.trim(), agent: v.agent, isolation: v.isolation, deliver: v.deliver };
      if (v.model.trim()) b.model = v.model.trim();
      if (v.avatar.trim()) b.avatar = v.avatar.trim();
      if (v.account) b.account = v.account;
      if (v.deliver === 'webhook' && v.webhookEntry.trim()) b.webhookEntry = v.webhookEntry.trim();
      if (v.deliver === 'inbox' && v.session.trim()) b.session = v.session.trim();
      if (skillsOf(v.skills).length) b.skills = skillsOf(v.skills);
      if (v.instructions.trim()) b.instructions = v.instructions;
      return b;
    }
    const b = { action: 'bot-set', name: bot.name };
    const keys = { identity: ['avatar', 'model'], runs: ['isolation'], reached: ['deliver', 'webhookEntry', 'session'], instructions: ['instructions', 'skills'], account: ['account'] }[tab] || [];
    for (const k of keys) {
      if (v[k] === was[k]) continue;
      if (k === 'skills') b.skills = skillsOf(v.skills);
      else if (k === 'deliver' || k === 'webhookEntry' || k === 'session') {
        b.deliver = v.deliver;
        if (v.deliver === 'webhook' && v.webhookEntry.trim()) b.webhookEntry = v.webhookEntry.trim();
        if (v.deliver === 'inbox' && v.session.trim()) b.session = v.session.trim();
      } else if (v[k] !== '' || k === 'instructions') b[k] = k === 'instructions' ? v[k] : v[k].trim();
    }
    return b;
  }

  /// Save: the one action; its line said in the form when it ends. Answers the operation ('done' | 'failed' | null).
  async function save() {
    err.textContent = '';
    done.textContent = '';
    if (readOnly) return null;
    if (utf8Bytes(v.instructions) > INSTRUCTIONS_MAX_BYTES) { err.textContent = 'The instructions are too long for this page — set them from a file in a terminal (the command is under the box).'; return null; }
    const b = body();
    if (isNew && !/^[a-z][a-z0-9-]{0,39}$/.test(b.name)) { err.textContent = 'Its name: a lower-case letter, then lower-case letters, digits and -, at most 40.'; return null; }
    if (!isNew && Object.keys(b).length <= 2) { err.textContent = 'Nothing changed on this tab.'; return null; }
    let op;
    try { op = await actOrThrow(b); } catch (e) { err.textContent = e.message || String(e); return null; }
    // Until it ends the form stays as it is (a live refresh keeps an unsaved page); a refusal is said here, the form kept.
    const end = await waitForOp(op, 120);
    if (!end || end.state !== 'done') { err.textContent = end ? end.text : 'It did not answer in time — see Operations.'; return end; }
    form.dirty = false;
    done.textContent = end.text;
    return end;
  }

  const el = h('div', { class: 'bot-form', 'data-bot-form': isNew ? '~new' : bot.name + '/' + tab }, notes, sections, err, done);
  return { el, save, form, values: v };
}
