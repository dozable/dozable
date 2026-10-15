// views/accounts — Accounts & keys.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { api } from '../core/api-2814f617dbd35bcd.js';
import { full, when } from '../core/format-b2e68384da8d2f36.js';
import { act } from '../core/operations-56949f5379c9806f.js';
import { refresh } from '../core/router-94400845dc4e72f8.js';
import { secretEntryAllowed } from '../core/settings-e508eb68e0b62892.js';
import { accountCommandsNode, accountForm } from '../components/accounts-5fdcb84f475c8132.js';
import { panel, table } from '../components/blocks-53c969feeec8fe89.js';
import { btn } from '../components/button-cbb8a60e3220f977.js';
import { confirmAction } from '../components/dialog-6e2b5c41ab058a33.js';
import { moreMenu } from '../components/menus-b1e7a64fdf6f51f5.js';
import { toast } from '../components/notices-0eac624a71d00e4f.js';

// A key its provider refused, or one that cannot be read, is a failure (red); signed out, expiring, not checked: a warning.
const stateClass = (s) => s === 'ok' ? 'st-ok' : s === 'rejected' || s === 'unavailable' || s === 'missing' ? 'st-fail' : 'st-warn';

export async function viewAccounts() {
  const a = await api('accounts');
  // A key read on use (1Password, AWS, a command): where it comes from and the last read; Refresh reads it again.
  // Adding or changing such a source is the CLI's (doz account add NAME --from …) — never this page's.
  const sourced = (x) => !!x.sourceLabel;
  const custom = (x) => x.provider === 'custom';
  const kindText = (x) => custom(x) ? 'custom key' : x.kind === 'key' && x.provider ? 'key, ' + x.provider : x.kind;
  // A key added without its check (doz account add --no-verify) has not been checked yet: said so, never the flag.
  const verificationText = (v) => !v ? null : /^unverified/.test(v) ? 'not checked yet' : v;
  // Each provider has its own default (Anthropic for Claude Code and pi, OpenAI for Codex, each key provider's for
  // its tools): the rows' "default" badges, listed together.
  const providerTitle = (x) => (a.sourceTitles && a.sourceTitles[x.provider]) || (x.kind === 'mac' || x.kind === 'api-key' || x.kind === 'setup-token' ? 'Anthropic' : x.provider || x.kind);
  const defaults = a.accounts.filter((x) => x.isDefault);
  const rows = a.accounts.map((x) => h('tr', null,
    h('td', null, x.name, x.isDefault ? h('span', { class: 'tag' }, 'default') : null),
    h('td', null, kindText(x), x.plan ? h('div', { class: 'muted' }, x.plan) : null,
      x.hosts && x.hosts.length ? h('div', { class: 'muted' }, 'only to ' + x.hosts.join(', ')) : null),
    h('td', null, x.identity || '—'),
    h('td', null, h('span', { class: stateClass(x.state), 'data-account-state': x.name }, x.state), verificationText(x.verification) ? h('div', { class: 'muted', 'data-verification': x.name }, verificationText(x.verification)) : null,
      x.sourceProblem ? h('div', { class: 'muted' }, x.sourceProblem) : null),
    h('td', null, x.expiresAt ? full(x.expiresAt) : '—', x.expiresAt ? h('div', { class: 'muted' }, when(x.expiresAt)) : null),
    h('td', { class: 'mono' }, x.fingerprint || '—',
      sourced(x) ? h('div', { class: 'muted' }, 'from ' + x.sourceLabel + (x.sourceState === 'unchecked' ? ' (not read yet)' : ''))
        : x.keychainService ? h('div', { class: 'muted' }, 'keychain: ' + x.keychainService) : null),
    h('td', null, x.usedBy.length ? x.usedBy.join(', ') : '—'),
    h('td', { class: 'row-acts-cell' }, (() => {
      const items = [
        x.isDefault || custom(x) ? null : { label: 'Make default', icon: 'star', desc: 'Sandboxes that follow the store default use it', onSelect: () => act({ action: 'account-default', account: x.name }) },
        sourced(x) ? { label: 'Refresh', icon: 'refresh-cw', desc: 'Read the key from where you keep it again now', onSelect: () => act({ action: 'account-refresh', account: x.name }) } : null,
        x.kind === 'mac' || x.isDefault ? null : { label: 'Verify', icon: 'badge-check', desc: 'One tiny request to the API with it', onSelect: () => act({ action: 'account-verify', account: x.name }) },
        x.name === 'mac' ? null : { sep: true },
        x.name === 'mac' ? null : { label: 'Remove…', icon: 'trash-2', danger: true, desc: sourced(x) ? 'Only Dozer’s record — where you keep the key is not touched' : 'Its keychain item is deleted', onSelect: () => confirmAction('Remove account ' + x.name,
          (sourced(x) ? 'Only Dozer’s record goes' : 'Its keychain item is deleted') + (x.usedBy.length ? '; sandboxes pinned to it must move first (' + x.usedBy.join(', ') + ')' : '') + '.', x.name, { action: 'account-rm', account: x.name }) },
      ].filter(Boolean);
      // The next verb: Refresh for a key read on use, Verify for a key or a token, else Make default; the rest in ⋯.
      const next = sourced(x) ? btn('Refresh', () => act({ action: 'account-refresh', account: x.name }), { small: true, quiet: true, title: 'Read the key from where you keep it again now' })
        : x.kind !== 'mac' ? btn('Verify', () => act({ action: 'account-verify', account: x.name }), { small: true, quiet: true, title: 'One tiny request to the API with it' })
        : x.isDefault ? null : btn('Make default', () => act({ action: 'account-default', account: x.name }), { small: true, quiet: true });
      const rest = items.filter((it) => it.sep || !next || it.label !== next.textContent.trim());
      while (rest.length && rest[0].sep) rest.shift();
      return h('div', { class: 'row-acts' }, next, rest.length ? moreMenu('More for ' + x.name, rest, { small: true }).el : null);
    })())));
  const keep = h('input', { type: 'checkbox', role: 'switch', id: 'keepalive' });
  keep.checked = a.keepalive;
  keep.addEventListener('change', () => act({ action: 'account-keepalive', enabled: keep.checked }));
  return h('div', null, h('h1', null, 'Accounts & keys'),
    h('p', { class: 'sub' }, 'Every provider’s keys and sign-ins the host holds for sandboxes — Anthropic, OpenAI, Google, xAI, the gateways and your own. Never a secret: states, keychain item names and fingerprints only.'),
    h('div', { class: 'stats' },
      h('div', { class: 'stat', 'data-defaults': '' }, h('div', { class: 'k' }, 'Defaults'),
        defaults.length
          ? h('ul', { class: 'defaults-list' }, ...defaults.map((x) => h('li', null, h('span', { class: 'muted' }, providerTitle(x) + ' '), h('strong', null, x.name))))
          : h('div', { class: 'v' }, 'none'),
        h('div', { class: 'n' }, 'a sandbox that follows the default uses its provider’s')),
      h('div', { class: 'stat' }, h('div', { class: 'k' }, 'Claude Code keep-alive'), h('label', { class: 'v switch-row' }, keep, a.keepalive ? 'on' : 'off'),
        h('div', { class: 'n' }, 'runs the Mac’s own claude -p near expiry while a sandbox uses the login'))),
    h('div', { class: 'head' }, h('h2', null, 'Accounts'), btn('No Anthropic default', () => act({ action: 'account-default', account: 'none' }), { small: true, title: 'Claude Code and pi sandboxes that follow the default get no account' })),
    panel(table(['Account', 'Kind', 'Identity', 'State', 'Expires', 'Fingerprint', 'Used by', ''], rows)),
    h('h2', null, 'Add an account'),
    secretEntryAllowed()
      ? accountForm({ kind: null,
          keyProviders: Object.entries(a.sourceTitles || {}).filter(([id]) => !['anthropic', 'openai', 'custom'].includes(id)).map(([id, title]) => ({ id, title })),
          onAdded: (r, name) => {
          const row = r.accounts.find((x) => x.name === name);
          toast('account ' + name + ' added' + (row && verificationText(row.verification) ? ' (' + verificationText(row.verification) + ')' : ''));
          refresh(false);
        } })
      : h('div', null, accountCommandsNode('setup-token'), accountCommandsNode('api-key')),
    h('p', { class: 'muted' }, 'Stored exactly as doz account add stores it: the login keychain (doz-anthropic:NAME, doz-openrouter:NAME, …), after one tiny check request. ',
      'This page keeps no copy. ui.allow_secret_entry (Settings) turns the field off.'),
    h('p', { class: 'muted' }, 'A key kept in 1Password, AWS Secrets Manager or read by a command, and a custom key for another service, are added with the doz command: ',
      h('code', null, 'doz account add NAME --provider xai --from op://VAULT/ITEM/FIELD'), ' · ', h('code', null, 'doz account add NAME --custom --host HOST --env-var VAR --bearer'), '.'));
}
