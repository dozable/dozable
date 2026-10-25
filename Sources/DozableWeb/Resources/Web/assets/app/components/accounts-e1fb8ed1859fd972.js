// components/accounts — Accounts (594): adding one from a key or a token, choosing one for an agent, a sandbox's own key.
import { upcall } from '../core/hooks-a4b871a481b363cd.js';
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { AGENT_NAMES, agentKey, isOpenAIAgent, KIND_LABELS } from '../core/agents-b5713528d20be964.js';
import { api } from '../core/api-0560a03cb0de25ef.js';
import { actOrThrow } from '../core/operations-773ff6e3f3377064.js';
import { secretEntryAllowed, secretEntryWhy } from '../core/settings-0b4a6cca79ee581c.js';
import { state } from '../core/state-dde742b9b2d6390c.js';
import { btn } from './button-f435595b4098d043.js';
import { callout } from './callout-045a1af4db6ce704.js';
import { dialog } from './dialog-ee9a9a31b03dc349.js';
import { toast } from './notices-b9b2a3550693d815.js';
// Calls up the layers (provided by app.js — core/hooks.js):
const refreshSandbox = upcall('refreshSandbox');

const ACCOUNT_COMMANDS = {
  'api-key': ['doz account add work --api-key       (it asks for the key, not echoed)', 'doz account default work'],
  // 599i: Codex — an OpenAI key, or Dozable's own ChatGPT sign-in (the browser opens on this Mac).
  'openai-key': ['doz account add openai --openai-key   (it asks for the key, not echoed)', 'doz account default openai'],
  chatgpt: ['doz account add chatgpt --chatgpt     (your browser opens: sign in with ChatGPT — Dozable’s own sign-in;',
    '                                       your Mac’s Codex login is not touched)', 'doz account default chatgpt'],
  'setup-token': ['claude setup-token                    (on this Mac: prints a 1-year token)',
    'doz account add work --setup-token   (paste it; not echoed)', 'doz account default work'],
};
export function accountCommandsNode(kind) {
  return h('div', { class: 'panel wiz-cmds' },
    h('div', { 'data-secret-why': secretEntryAllowed() ? null : '1' }, secretEntryAllowed() ? 'In a terminal on this Mac:' : 'Not here: ' + secretEntryWhy() + ' in a terminal on this Mac:'),
    h('pre', { class: 'mono' }, ACCOUNT_COMMANDS[kind].join('\n')));
}
/// 617 (models@1): the model source an account's key is of (nil: a subscription or a login).
export function sourceOf(x) { return x.kind === 'api-key' ? 'anthropic' : x.kind === 'openai-key' ? 'openai' : x.kind === 'key' ? x.provider : null; }
/// The account kind a source's key is added as.
function kindForSource(src) { return src === 'anthropic' ? 'api-key' : src === 'openai' ? 'openai-key' : 'key'; }

/// opts: {kind (fixed) | null (a choice), name, onAdded(result, name)}; 617: or {sources, titles} — a key of one of
/// these model sources (a provider or gateway), chosen in the form.
export function accountForm(opts) {
  const kindSel = opts.sources
    ? h('select', { name: 'acct-source', 'aria-label': 'Provider or gateway' }, ...opts.sources.map((x) => h('option', { value: x }, (opts.titles || {})[x] || x)))
    : h('select', { name: 'acct-kind', 'aria-label': 'Kind' },
      h('option', { value: 'api-key' }, 'Anthropic API key'), h('option', { value: 'setup-token' }, 'Claude setup token'),
      h('option', { value: 'openai-key' }, 'OpenAI API key'),
      // 617: every other provider's or gateway's key (xAI, Google, OpenRouter, …) — a `key` account of that provider.
      ...(opts.keyProviders || []).map((p) => h('option', { value: 'key:' + p.id }, p.title + ' key')));
  // Only the kinds this agent can use (the chooser's "Add a key or account…").
  if (opts.kinds && !opts.sources) for (const o of [...kindSel.options]) if (!opts.kinds.includes(o.value)) o.remove();
  if (opts.kind) kindSel.value = opts.kind;
  const keyProvider = () => (!opts.sources && kindSel.value.startsWith('key:') ? kindSel.value.slice(4) : null);
  const keyTitle = () => ((opts.keyProviders || []).find((p) => p.id === keyProvider()) || {}).title || keyProvider();
  const kindNow = () => (opts.sources ? kindForSource(kindSel.value) : keyProvider() ? 'key' : kindSel.value);
  const name = h('input', { type: 'text', name: 'acct-name', autocomplete: 'off', spellcheck: 'false', placeholder: 'a-z 0-9 -' });
  name.value = opts.name || 'work';
  const plan = h('select', { name: 'acct-plan', 'aria-label': 'Plan' }, ['max', 'pro', 'team', 'enterprise'].map((p) => h('option', { value: p }, p)));
  const secret = h('input', { type: 'password', name: 'acct-secret', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
                              'data-secret': '1', placeholder: 'paste it here' });
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  const planRow = h('label', { class: 'field' }, h('span', null, 'Plan (what Claude Code shows; it picks its default model by it)'), plan);
  const secretLabel = h('span', null, '');
  const hint = h('small', null, '');
  const paint = () => {
    const token = kindNow() === 'setup-token';
    planRow.hidden = !token;
    secretLabel.textContent = token ? 'Setup token' : 'API key';
    hint.textContent = opts.sources ? 'A ' + ((opts.titles || {})[kindSel.value] || kindSel.value) + ' key — only ever sent there. Not shown, not kept in this page.'
      : keyProvider() ? 'Your ' + keyTitle() + ' key — only ever sent there. Not shown, not kept in this page.'
      : token ? 'Run claude setup-token on this Mac and paste what it prints (it starts sk-ant-oat…; valid a year). Not shown, not kept in this page.'
      : kindSel.value === 'openai-key' ? 'An OpenAI API key (sk-…) for Codex. Not shown, not kept in this page.'
      : 'An Anthropic API key (sk-ant-api…). Not shown, not kept in this page.';
  };
  kindSel.addEventListener('change', paint);
  paint();
  const add = btn('Add account', async (ev) => {
    const b = ev.currentTarget;
    error.textContent = '';
    const value = secret.value;
    secret.value = '';                                     // gone from the page before the request
    const n = name.value.trim();
    if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(n) || n === 'default' || n === 'none') { error.textContent = 'The name: 1–40 of a-z 0-9 - (not default or none).'; return; }
    if (value.trim().length < 20) { error.textContent = 'Paste the whole ' + (kindNow() === 'setup-token' ? 'token' : 'key') + '.'; return; }
    b.disabled = true;
    try {
      const body = { name: n, kind: kindNow(), secret: value };
      if (kindNow() === 'setup-token') body.plan = plan.value;
      if (opts.sources && kindNow() === 'key') body.provider = kindSel.value;
      if (keyProvider()) body.provider = keyProvider();
      const r = await api('accounts', { method: 'POST', json: body });
      opts.onAdded(r, n);
    } catch (e) {
      error.textContent = e.message || String(e);
    } finally {
      b.disabled = false;
    }
  }, { primary: true, icon: 'key-round' });
  return h('div', { class: 'panel acct-form' },
    opts.kind ? null : h('label', { class: 'field' }, h('span', null, opts.sources ? 'Provider or gateway' : 'Kind'), kindSel),
    h('label', { class: 'field' }, h('span', null, 'Account name'), name),
    planRow,
    h('label', { class: 'field' }, secretLabel, secret, hint),
    error,
    h('div', { class: 'wiz-buttons' }, add));
}
/// What an agent can use from these accounts: {kinds, srcs, needs (a key is required), usable (the rows that fit),
/// defName (the default it follows — 'none'), def (that row, when it fits), defFits}. 641: Accounts & keys' Sandboxes
/// view changes a sandbox's key in place with it.
export function usableFor(acc, current) {
  const kinds = current && acc.agents ? acc.agents[agentKey(current, acc.agents)] : null;
  // 617 (models@1): a recipe agent takes a key of one of its model sources (a provider or gateway) — never a subscription.
  const srcs = current && acc.sources ? acc.sources[agentKey(current, acc.sources)] || null : null;
  const needs = !!kinds && !kinds.includes('mac');
  const usable = acc.accounts.filter((x) => (!kinds || kinds.includes(x.kind)) && (!srcs || srcs.includes(sourceOf(x))));
  // 599i: Codex follows the store's OpenAI default (none until one is chosen), never the Anthropic one. 617: a recipe
  // agent the default of its first source that has one (the host's own choice).
  const defName = srcs ? ((acc.recipeDefaults || {})[agentKey(current, acc.sources)] || 'none')
    : isOpenAIAgent(kinds) ? (acc.openaiDefault || 'none') : acc.defaultAccount;
  // Two rows can be named mac (Claude's and, rc.3, this Mac's Codex login): the one this agent can use.
  const def = usable.find((x) => x.name === defName) || null;
  const defFits = defName !== 'none' ? !!def : !needs;
  return { kinds, srcs, needs, usable, defFits, defName, def };
}

const ADD = '__add';
export function accountChooser({ accounts, agent, same = null, defaultValue = '', value = null, onChange = () => {} }) {
  let acc = accounts, current = agent(), chosen = value;            // 599f: `value` pre-selects (a project file's account)
  const el = h('div', { class: 'field acct-chooser', 'data-acct-chooser': '' });
  const title = (src) => (acc.sourceTitles || {})[src] || src;
  function render() {
    const s = usableFor(acc, current);
    const opts = [];
    if (same) opts.push(['', same]);
    if (s.defFits) opts.push([defaultValue, 'the store default (' + s.defName + ')']);
    for (const x of s.usable) opts.push([x.name, x.name + ' (' + (s.srcs ? title(sourceOf(x)) + ' key' : KIND_LABELS[x.kind] || x.kind) + ')']);
    if (!s.needs) opts.push(['none', 'No key or account']);
    // Owner, 2026-10-23: "i should be able to add a key" — here, without leaving the flow.
    const addable = (s.kinds || []).filter((k) => ['api-key', 'setup-token', 'openai-key'].includes(k));
    const canAdd = secretEntryAllowed() && (s.srcs ? s.srcs.length > 0 : addable.length > 0);
    if (canAdd) opts.push([ADD, 'Add a key or account…']);
    const sel = h('select', { name: 'account', 'aria-label': 'Account' }, opts.map(([v, l]) => h('option', { value: v }, l)));
    if (chosen !== null && opts.some(([v]) => v === chosen)) sel.value = chosen;
    chosen = sel.value;
    const name = AGENT_NAMES[current] || current;
    const extra = h('div', { class: 'acct-extra' });
    const paintExtra = () => {
      el.dataset.acctOk = String(!(s.needs && !s.usable.length) && chosen !== ADD);
      if (chosen === ADD) {
        const first = s.srcs ? s.srcs[0] : addable[0];
        const base = s.srcs ? first : first === 'openai-key' ? 'openai' : 'anthropic';
        extra.replaceChildren(accountForm({ sources: s.srcs || undefined, titles: acc.sourceTitles || {}, kinds: s.srcs ? undefined : addable,
          kind: s.srcs || addable.length > 1 ? null : first, name: acc.accounts.some((x) => x.name === base) ? base + '-2' : base,
          onAdded: (r, n) => { acc = r; chosen = n; toast('account ' + n + ' added'); render(); onChange(); } }));
        return;
      }
      // Owner, 2026-10-23: "if i choose no key / account then add a note that the tool will require a login".
      const none = chosen === 'none' || (chosen === defaultValue && s.defName === 'none' && !same);
      extra.replaceChildren(none && current
        ? callout('info', { compact: true, icon: 'user-round', attrs: { 'data-acct-login-note': '' },
          body: h('small', null, name + ' will ask you to sign in when it starts' + (current === 'claude-code' ? ' (/login)' : '')
            + ' — the sign-in stays in this sandbox and is deleted with it.') })
        : '');
    };
    sel.addEventListener('change', () => { chosen = sel.value; paintExtra(); onChange(); });
    const missing = s.needs && !s.usable.length;
    el.dataset.acctOk = String(!missing && chosen !== ADD);
    const parts = [h('span', null, 'Account')];
    if (!missing) { parts.push(sel, extra); paintExtra(); }
    if (s.srcs && current) {
      parts.push(h('small', { class: 'muted' }, name + ' can use a key of ' + s.srcs.map(title).join(', ')
        + ' — the account decides which; never a subscription'));
    } else if (s.kinds && current) {
      parts.push(h('small', { class: 'muted' }, name + ' can use: ' + s.kinds.map((k) => KIND_LABELS[k] || k).join(', ')
        + (isOpenAIAgent(s.kinds) ? ' — never a Claude account' : s.needs ? ' — never a Claude subscription' : '')));
    }
    if (missing && s.srcs) {
      // 617 (models@1): a key of one of its sources, typed here (or the command).
      const first = s.srcs[0];
      parts.push(callout('warn', { cls: 'acct-need', icon: 'key-round', attrs: { 'data-acct-need': current }, title: name + ' needs an API key',
        body: [h('small', null, 'A key of ' + s.srcs.map(title).join(', ') + ' — stored as `doz account add` stores it (the login keychain); the sandbox only ever sees a placeholder.'),
          secretEntryAllowed()
            ? accountForm({ sources: s.srcs, titles: acc.sourceTitles || {}, name: acc.accounts.some((x) => x.name === first) ? first + '-2' : first,
                onAdded: (r, n) => { acc = r; chosen = n; toast('account ' + n + ' added'); render(); onChange(); } })
            : h('div', { class: 'panel wiz-cmds' }, h('pre', { class: 'mono' }, 'doz account add NAME --provider ' + first)),
          btn('Check again', async () => { try { acc = await api('accounts'); } catch (_) { /* keep */ } render(); onChange(); }, { small: true, icon: 'refresh-cw' })].filter(Boolean) }));
    } else if (missing && isOpenAIAgent(s.kinds)) {
      // 599i: Codex — Dozable's own ChatGPT sign-in runs in a terminal (the browser opens on this Mac); a key can be typed here.
      parts.push(callout('warn', { cls: 'acct-need', icon: 'key-round', attrs: { 'data-acct-need': current }, title: name + ' needs an OpenAI account',
        body: [h('small', null, (state.chatgptSignIn ? 'Sign in with ChatGPT (your plan) in a terminal, or add an OpenAI API key' : 'Sign in with Codex on this Mac (the account mac), or add an OpenAI API key')
            + ' — stored as `doz account add` stores it (the login keychain); the sandbox only ever sees a placeholder.'),
          state.chatgptSignIn ? accountCommandsNode('chatgpt') : null,
          secretEntryAllowed()
            ? accountForm({ kind: 'openai-key', name: acc.accounts.some((x) => x.name === 'openai') ? 'openai-2' : 'openai',
                onAdded: (r, n) => { acc = r; chosen = n; toast('account ' + n + ' added'); render(); onChange(); } })
            : accountCommandsNode('openai-key'),
          btn('Check again', async () => { try { acc = await api('accounts'); } catch (_) { /* keep */ } render(); onChange(); }, { small: true, icon: 'refresh-cw' })].filter(Boolean) }));
    } else if (missing) {
      parts.push(callout('warn', { cls: 'acct-need', icon: 'key-round', attrs: { 'data-acct-need': current }, title: name + ' needs an Anthropic API key',
        body: [h('small', null, 'Add one now — it is stored as `doz account add` stores it (the login keychain), and this sandbox uses it.'),
          secretEntryAllowed()
            ? accountForm({ kind: 'api-key', name: acc.accounts.some((x) => x.name === 'anthropic') ? 'anthropic-2' : 'anthropic',
                onAdded: (r, n) => { acc = r; chosen = n; toast('account ' + n + ' added'); render(); onChange(); } })
            : accountCommandsNode('api-key')] }));
    }
    el.replaceChildren(...parts);
  }
  render();
  return {
    el,
    /// The image changed: its agent's accounts.
    agentChanged() { current = agent(); chosen = null; render(); onChange(); },
    ok() { return el.dataset.acctOk === 'true'; },
    /// The account to send (undefined: the store default / the same).
    get() { return chosen && chosen !== ADD ? chosen : undefined; },
  };
}

/// 594: which account a sandbox uses — only the ones its agent can use (and the key right there when
/// none fits). It applies to the sandbox's next session.
export function accountDialog(name, i, accounts) {
  const slot = h('div');
  let acct = null;
  const dlg = dialog('Account of ' + name, 'Which account the proxy uses for it — from its next session. The guest only ever sees a placeholder.',
    [{ name: 'account', type: 'custom', el: slot, get: () => {
      if (!acct.ok()) throw new Error((AGENT_NAMES[agentKey(i.agent, AGENT_NAMES)] || 'This agent') + ' needs an account it can use — add one above.');
      return acct.get() || 'default';
    } }], 'Use', async (v) => {
      await actOrThrow({ action: 'account-use', sandbox: name, account: v.account });
    });
  const submit = dlg.querySelector('button[type="submit"]');
  acct = accountChooser({ accounts, agent: () => i.agent, defaultValue: 'default', onChange: () => { submit.disabled = !acct.ok(); } });
  slot.replaceWith(acct.el);
  submit.disabled = !acct.ok();
}

/// 594: an existing sandbox whose account does not fit its agent — "pi can't use the account mac —
/// choose an API-key account" — with the accounts that fit (or the key field) right there.
export function credentialBanner(name, i, accounts) {
  return callout('bad', { compact: true, cls: 'cred-banner', icon: 'key-round', attrs: { 'data-cred-banner': name }, body: i.credentialProblem,
    actions: [btn('Choose an account…', () => accountDialog(name, i, accounts), { small: true, primary: true, icon: 'key-round' })] });
}

/// 594 (owner ruling: sandbox keys in the browser too): a sandbox's own Anthropic key — what `doz key set
/// NAME --anthropic` does — under the same setting and rules as accountForm: a masked field, emptied
/// before the request, one CSRF-checked POST /api/v1/sandboxes/NAME/key body; off: the commands.
export function keyEntry(name, proxied) {
  if (!proxied) return h('p', { class: 'muted' }, 'Not proxied: a key would have to enter the sandbox — create it with a proxied network (agent, open, …) to give it one.');
  if (!secretEntryAllowed()) {
    return h('div', { class: 'panel wiz-cmds', 'data-key-commands': name },
      h('div', { 'data-secret-why': '1' }, 'Not here: ' + secretEntryWhy() + ' in a terminal on this Mac:'),
      h('pre', { class: 'mono' }, ['doz key set ' + name + ' --anthropic                       (it asks for the key, not echoed)',
        'doz key set ' + name + ' --anthropic --keychain SERVICE      (read from a keychain item)'].join('\n')));
  }
  const secret = h('input', { type: 'password', name: 'key-secret', autocomplete: 'off', spellcheck: 'false', autocapitalize: 'off',
                              'data-secret': '1', placeholder: 'sk-ant-api… — paste it here' });
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  const set = btn('Set key', async (ev) => {
    const b = ev.currentTarget;
    error.textContent = '';
    const value = secret.value;
    secret.value = '';                                     // gone from the page before the request
    if (value.trim().length < 20) { error.textContent = 'Paste the whole key.'; return; }
    b.disabled = true;
    try {
      await api('sandboxes/' + name + '/key', { method: 'POST', json: { secret: value } });
      toast('anthropic key set for ' + name + ' (held by the host, in memory; never in the sandbox)');
      refreshSandbox();
    } catch (e) {
      error.textContent = e.message || String(e);
    } finally {
      b.disabled = false;
    }
  }, { primary: true, small: true, icon: 'key-round' });
  return h('div', { class: 'panel acct-form key-form', 'data-key-form': name },
    h('label', { class: 'field' }, h('span', null, 'Set an Anthropic API key for ' + name), secret,
      h('small', null, 'Held by the host in memory (as doz key set from a prompt): it lasts while the host runs, replaces this sandbox’s account, and the guest only ever sees a placeholder. Not shown, not kept in this page.')),
    error, h('div', { class: 'wiz-buttons' }, set),
    h('div', { class: 'muted' }, 'From a keychain item instead: ', h('code', null, 'doz key set ' + name + ' --anthropic --keychain SERVICE'), ' in a terminal.'));
}
