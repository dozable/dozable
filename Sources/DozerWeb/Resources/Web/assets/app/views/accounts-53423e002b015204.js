// views/accounts — Accounts & keys.
import { h } from '../dom/h-d909ae8eb40113fe.js';
import { api } from '../core/api-2e66c14d90f7f83a.js';
import { full, when } from '../core/format-b2e68384da8d2f36.js';
import { act } from '../core/operations-73b26effbe04935d.js';
import { refresh } from '../core/router-01efde03fb80ec68.js';
import { secretEntryAllowed } from '../core/settings-70247ce370cb44d9.js';
import { accountCommandsNode, accountForm } from '../components/accounts-73db360e69ed6079.js';
import { card, panel, table } from '../components/blocks-53c969feeec8fe89.js';
import { btn } from '../components/button-72d87e1085f00b4e.js';
import { confirmAction } from '../components/dialog-fd6b35c90abaf5e6.js';
import { moreMenu } from '../components/menus-08caea0a1297bf90.js';
import { toast } from '../components/notices-22eb175bdbf9c19c.js';

export async function viewAccounts() {
  const a = await api('accounts');
  // A key read on use (1Password, AWS, a command): where it comes from and the last read; Refresh reads it again.
  // Adding or changing such a source is the CLI's (doz account add NAME --from …) — never this page's.
  const sourced = (x) => !!x.sourceLabel;
  const custom = (x) => x.provider === 'custom';
  const kindText = (x) => custom(x) ? 'custom key' : x.kind === 'key' && x.provider ? 'key, ' + x.provider : x.kind;
  const rows = a.accounts.map((x) => h('tr', null,
    h('td', null, x.name, x.isDefault ? h('span', { class: 'tag' }, 'default') : null),
    h('td', null, kindText(x), x.plan ? h('div', { class: 'muted' }, x.plan) : null,
      x.hosts && x.hosts.length ? h('div', { class: 'muted' }, 'only to ' + x.hosts.join(', ')) : null),
    h('td', null, x.identity || '—'),
    h('td', null, h('span', { class: x.state === 'ok' ? 'st-ok' : 'st-warn' }, x.state), x.verification ? h('div', { class: 'muted' }, x.verification) : null,
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
    h('p', { class: 'sub' }, 'Anthropic credentials the host holds for sandboxes. Never a secret: states, keychain item names and fingerprints only.'),
    h('div', { class: 'stats' },
      card('Default account', a.defaultAccount, a.defaultAccount === 'none' ? 'sandboxes that follow it get none' : ''),
      h('div', { class: 'stat' }, h('div', { class: 'k' }, 'Keep-alive'), h('label', { class: 'v switch-row' }, keep, a.keepalive ? 'on' : 'off'),
        h('div', { class: 'n' }, 'runs the Mac’s own claude -p near expiry while a sandbox uses the login'))),
    h('div', { class: 'head' }, h('h2', null, 'Accounts'), btn('Set the default to none', () => act({ action: 'account-default', account: 'none' }), { small: true })),
    panel(table(['Account', 'Kind', 'Identity', 'State', 'Expires', 'Fingerprint', 'Used by', ''], rows)),
    h('h2', null, 'Add an account'),
    secretEntryAllowed()
      ? accountForm({ kind: null, onAdded: (r, name) => {
          const row = r.accounts.find((x) => x.name === name);
          toast('account ' + name + ' added' + (row && row.verification ? ' (' + row.verification + ')' : ''));
          refresh(false);
        } })
      : h('div', null, accountCommandsNode('setup-token'), accountCommandsNode('api-key')),
    h('p', { class: 'muted' }, 'Stored exactly as doz account add stores it: the login keychain (doz-claude:NAME, doz-anthropic:NAME), after one tiny check request. ',
      'This page keeps no copy. ui.allow_secret_entry (Settings) turns the field off.'),
    h('p', { class: 'muted' }, 'A key kept in 1Password, AWS Secrets Manager or read by a command, and a custom key for another service, are added with the doz command: ',
      h('code', null, 'doz account add NAME --provider xai --from op://VAULT/ITEM/FIELD'), ' · ', h('code', null, 'doz account add NAME --custom --host HOST --env-var VAR --bearer'), '.'));
}
