// views/settings — Settings (591).
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { api } from '../core/api.js';
import { refresh } from '../core/router.js';
import { adoptSettings, applyDensity, resetSetting, saveSetting, setting } from '../core/settings.js';
import { state } from '../core/state.js';
import { isInt } from '../core/util.js';
import { isRemote } from '../core/session.js';
import { renderAccessStep } from '../components/access-step.js';
import { pageIndex } from '../components/blocks.js';
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { pageFailure, toast } from '../components/notices.js';
import { confirmWeb, isAgentModel, permissionSwitches } from '../components/permissions.js';
import { dialog } from '../components/dialog.js';
import { sourceBadge, sourceLegend, sourceTag } from '../components/setting-source.js';
import { mark } from '../dom/icons.js';
import { bytes, plural } from '../core/format.js';
import { actOrThrow } from '../core/operations.js';

const SETTING_SECTIONS = {
  ui: 'This UI', host: 'The host', store: 'The store', defaults: 'New sandboxes', agent: 'The agent', sandbox: 'Inside every sandbox',
  'images.lab': 'New lab sandboxes', kernel: 'The kernel',
  resources: 'Resources', sessions: 'Sessions', bridges: 'Bridges', workspace: 'Workspace rules', github: 'GitHub', images: 'Images', telemetry: 'Usage statistics',
};
// An empty app list (or dotfiles) means none, not "automatic".
function shownValue(v, type) { return typeof v === 'string' ? (v === '' ? (type === 'apps' || type === 'dotfiles' ? '""  (none)' : '""  (automatic)') : v) : String(v); }
export async function viewSettings() {
  // 669: a recipe's own page (#/settings/recipes/V/P).
  if (state.recipe) return viewRecipe(state.recipe);
  const [report, recipes] = await Promise.all([api('settings'), api('recipes').catch(() => null)]);
  adoptSettings(report);
  const rep = state.settings.report;
  const sections = [];
  // 669: a recipe's settings are on its own page (Settings › Recipes), never in Dozable's sections.
  for (const r of rep.settings.filter((x) => !x.agent)) {
    let s = sections.find((x) => x.name === r.section);
    if (!s) sections.push(s = { name: r.section, rows: [] });
    s.rows.push(r);
  }
  const warnings = rep.warnings.filter((w) => !rep.error || !w.startsWith(rep.error));
  // 599e: Access — each credential's last confirmation and "Check again" (the choices are the settings
  // below: defaults.github, github.credentials, sandbox.ssh_agent; the Claude account: Accounts).
  const accessBox = h('div', { class: 'panel access-panel', 'data-settings-access': '' });
  renderAccessStep(accessBox, { mode: 'settings', claude: true });
  // 603 (E13): a filter over what the page already has (a key, a name, a description) and an index of the
  // sections; Access stays first.
  const filter = h('input', { type: 'search', class: 'page-filter', 'data-settings-filter': '', placeholder: 'Filter — a key like ui.theme, a recipe like claude, or a word',
    'aria-label': 'Filter the settings', autocomplete: 'off', spellcheck: 'false' });
  filter.value = state.settingsFilter || '';
  const secId = (name) => 'set-' + name.replace(/[^a-z0-9]+/gi, '-');
  const listed = recipes ? recipes.recipes.filter((r) => r.state !== 'available') : [];
  const index = pageIndex([['recipes', 'Recipes ' + listed.length], ['access', 'Access'], ...sections.map((sec) => [secId(sec.name), SETTING_SECTIONS[sec.name] || sec.name])]);
  const node = h('div', { class: 'settings-page' }, h('h1', null, 'Settings'),
    h('p', { class: 'sub' }, 'Written to ', h('code', null, rep.path || 'no file (neither XDG_CONFIG_HOME nor HOME is set)'),
      rep.exists ? '' : ' — not written yet: the first change writes it, with every setting listed at its default',
      '. A command-line flag wins, then the environment, then a sandbox’s own value, then its project’s (', h('code', null, 'doz_project.yaml'),
      '), then this Mac’s (this file), then the default — a recipe’s own, or Dozable’s; ', h('code', null, 'doz config show'), ' prints the same.'),
    sourceLegend(),
    rep.error ? callout('bad', { cls: 'notice', title: 'The settings file does not read', body: rep.error + ' — nothing in it applies, and the UI will not overwrite it. Fix it (or remove it) first.' }) : null,
    warnings.length ? callout('warn', { cls: 'notice', body: h('ul', { class: 'plain' }, warnings.map((w) => h('li', null, w))) }) : null,
    h('div', { class: 'page-tools' }, h('label', { class: 'filter-field' }, icon('search'), filter), index),
    h('p', { class: 'muted filter-none', 'data-filter-none': '', hidden: true }, 'No setting matches.'),
    recipesSection(recipes),
    h('h2', { id: 'access', class: 'set-head' }, 'Access'),
    h('p', { class: 'sub' }, 'What sandboxes may use as you. Change a choice in the settings below (',
      h('code', null, 'defaults.github'), ', ', h('code', null, 'github.credentials'), ', ', h('code', null, 'sandbox.ssh_agent'),
      ') or with ', h('code', null, 'doz access set'), '; the Claude account on the Accounts page.'),
    accessBox,
    sections.flatMap((sec) => [
      h('h2', { id: secId(sec.name), class: 'set-head', 'data-section': sec.name }, SETTING_SECTIONS[sec.name] || sec.name, ' ', h('code', { class: 'muted' }, '[' + sec.name + ']')),
      h('div', { class: 'panel settings', 'data-section': sec.name }, sec.rows.map(settingRow)),
    ]),
    h('h2', { class: 'set-head', 'data-section': 'not-settable' }, 'Not settable, by design'),
    h('div', { class: 'panel', 'data-section': 'not-settable' }, h('ul', { class: 'plain' }, rep.notSettable.map((n) => h('li', null, n)))));
  const apply = () => {
    const q = filter.value.trim().toLowerCase();
    state.settingsFilter = filter.value;
    let any = false;
    for (const row of node.querySelectorAll('.setting[data-key]')) {
      const r = state.settings.byKey[row.dataset.key];
      const hit = !q || [r.key, r.name, r.description, r.section].some((t) => String(t || '').toLowerCase().includes(q));
      row.hidden = !hit;
      any = any || hit;
    }
    for (const el of node.querySelectorAll('[data-section]')) {
      const box = node.querySelector('.panel.settings[data-section="' + el.dataset.section + '"]');
      el.hidden = !!q && (!box || ![...box.querySelectorAll('.setting')].some((x) => !x.hidden));
    }
    // 669: a listed recipe by its name, full name or subject ("claude" lands on Claude Code's row).
    let recipeHit = false;
    for (const row of node.querySelectorAll('.recipe-row[data-recipe-search]')) {
      const hit = !q || row.dataset.recipeSearch.includes(q);
      row.hidden = !hit;
      recipeHit = recipeHit || (hit && !!q);
    }
    const rs = node.querySelector('[data-recipes-section]');
    if (rs) rs.hidden = !!q && !recipeHit;
    any = any || recipeHit;
    // Access and the index stand aside while filtering (the matching rows are the page).
    for (const el of node.querySelectorAll('#access, [data-settings-access], #access + .sub')) el.hidden = !!q;
    node.querySelector('[data-filter-none]').hidden = !q || any;
  };
  filter.addEventListener('input', apply);
  filter.addEventListener('keydown', (ev) => { if (ev.key === 'Escape' && filter.value) { ev.stopPropagation(); filter.value = ''; apply(); } });
  apply();
  return node;
}
function settingRow(r) {
  const source = sourceBadge(r);
  // 669: "Default" resets this Mac's value only (the file's line commented out).
  const reset = r.editable && (r.source === 'mac' || r.source === 'file')
    ? btn('Default', () => changeSetting(r.key, null), { small: true, title: 'Comment it out in the file: the default (' + shownValue(r.defaultValue, r.type) + ') applies' }) : null;
  // 602: a control that is a block of its own (the permissions checklist) goes UNDER the text, full
  // width — beside it, its max-content width squeezed the description to one word per line.
  const row = h('div', { class: r.type === 'permissions' ? 'setting setting-wide' : 'setting', 'data-key': r.key },
    h('div', { class: 'setting-main' },
      h('div', { class: 'setting-name' }, h('code', null, r.name), ' ', source),
      h('div', null, r.description),
      h('div', { class: 'muted setting-meta' }, 'default ', h('code', null, shownValue(r.defaultValue, r.type)), ' · ', r.appliesNote,
        r.note ? h('div', null, r.note) : null)),
    h('div', { class: 'setting-control' }, settingControl(r), reset));
  if (state.settingErr.has(r.key)) paintSettingError(row, r.key);
  return row;
}
// ── 669: Settings › Recipes (659 §0, layout A) ───────────────────────────────
// The recipes on this Mac, grouped by state: In use (a sandbox runs its agent), then Installed (a baked image of it, or
// this Mac's values with none: "not installed"). The rest of the catalogue only through the search and Browse. A row
// opens the recipe's page (#/settings/recipes/V/P): its settings, its baked images, its sandboxes, Uninstall.
function recipeHash(r) { return '#/settings/recipes/' + r.qualified; }
function shown(v) { return typeof v === 'string' ? (v === '' ? '""' : v) : String(v); }
function recipeRow(r) {
  const set = r.settings.filter((s) => s.source === 'mac');
  const meta = [];
  if (r.state === 'in use') meta.push(plural(r.sandboxes.length, 'sandbox', 'sandboxes') + ' · ' + r.sandboxes.slice(0, 3).join(', ') + (r.sandboxes.length > 3 ? ', …' : ''));
  if (r.images.length) meta.push(plural(r.images.length, 'baked image', 'baked images') + ' · ' + bytes(r.imageBytes));
  else if (r.state !== 'available') meta.push('no baked image');
  if (r.state === 'available') meta.push('in the catalogue');
  const tags = [h('span', { class: 'tag outline' }, r.source)];
  if (r.isDefault) tags.unshift(h('span', { class: 'tag info', title: 'your default image’s agent (defaults.image)' }, '★ default'));
  if (r.notInstalled) tags.push(h('span', { class: 'tag warn', title: 'it carries your settings on this Mac, but no baked image' }, 'not installed'));
  if (!r.published) tags.push(h('span', { class: 'tag', title: 'not offered for a new sandbox in this version' }, 'unpublished'));
  return h('a', { class: 'recipe-row', href: recipeHash(r), 'data-recipe': r.qualified,
                  'data-recipe-search': [r.title, r.qualified, r.id, r.subject].join(' ').toLowerCase() },
    mark(r.icon, 'recipe-mark'),
    h('span', { class: 'recipe-main' },
      h('span', { class: 'recipe-name' }, r.title, h('span', { class: 'muted' }, ' · ' + r.subject)),
      h('span', { class: 'recipe-q' }, r.qualified),
      h('span', { class: 'recipe-meta' }, meta.join(' · '), ' ', tags),
      set.length ? h('span', { class: 'recipe-chips' }, set.map((s) => h('span', { class: 'chip-set' }, h('code', null, s.name), ' ' + shown(s.value) + ' ', sourceBadge(s)))) : null),
    h('span', { class: 'recipe-count muted' }, set.length ? set.length + ' set on this Mac' : 'the recipe’s defaults'), icon('chevron-right'));
}
function recipesSection(data) {
  const box = h('div', { 'data-recipes-section': '' });
  if (!data) {
    box.append(h('h2', { id: 'recipes', class: 'set-head' }, 'Recipes'), callout('warn', { cls: 'notice', body: 'The recipes could not be read.' }));
    return box;
  }
  const all = data.recipes;
  const paint = () => {
    const inUse = all.filter((r) => r.state === 'in use'), installed = all.filter((r) => r.state === 'installed');
    const q = state.recipeQuery.trim().toLowerCase();
    const available = all.filter((r) => r.state === 'available');
    const found = q ? available.filter((r) => [r.title, r.qualified, r.id, r.subject].join(' ').toLowerCase().includes(q))
      : state.recipeBrowse ? available : null;
    const group = (title, rows, empty) => [h('div', { class: 'recipe-group' }, title + ' · ' + rows.length),
      rows.length ? h('div', { class: 'recipe-list' }, rows.map(recipeRow)) : h('div', { class: 'recipe-empty muted' }, empty)];
    const search = h('input', { type: 'search', class: 'page-filter', 'data-recipe-catalogue': '', placeholder: 'Search the catalogue — a name, a vendor, what it is',
      'aria-label': 'Search the recipe catalogue', autocomplete: 'off', spellcheck: 'false' });
    search.value = state.recipeQuery;
    search.addEventListener('input', () => { state.recipeQuery = search.value; paint(); const n = box.querySelector('[data-recipe-catalogue]'); n.focus(); n.setSelectionRange(n.value.length, n.value.length); });
    const browse = btn(state.recipeBrowse ? 'Hide the catalogue' : 'Browse', () => { state.recipeBrowse = !state.recipeBrowse; paint(); }, { small: true, icon: 'list' });
    box.replaceChildren(
      h('h2', { id: 'recipes', class: 'set-head' }, 'Recipes ', h('code', { class: 'muted' }, '[recipes.*]')),
      h('p', { class: 'sub' }, 'The recipes on this Mac: in use (a sandbox runs its agent) and installed (a baked image of it). A recipe’s settings come with it; open one to change them on this Mac, see its baked images and its sandboxes, or uninstall it. A project (',
        h('code', null, 'approvals:'), ' in doz_project.yaml) or one sandbox can set its own.'),
      h('div', { class: 'panel recipes-panel' },
        group('In use', inUse, 'No sandbox runs a recipe’s agent.'),
        group('Installed', installed, 'No other recipe has a baked image on this Mac.'),
        h('div', { class: 'recipe-tools' }, h('label', { class: 'filter-field' }, icon('search'), search), browse),
        found ? [h('div', { class: 'recipe-group' }, (q ? 'In the catalogue: “' + q + '”' : 'The catalogue') + ' · ' + found.length),
                 found.length ? h('div', { class: 'recipe-list' }, found.map(recipeRow)) : h('div', { class: 'recipe-empty muted' }, 'No recipe matches. Every installed one is listed above.')]
          : h('div', { class: 'recipe-empty muted' }, plural(available.length, 'more recipe', 'more recipes') + ' in the catalogue — search to find one, or Browse.')));
  };
  paint();
  return box;
}
/// 669 (item 12): one recipe's page — its state, its settings (each with its badge; "Default" resets this Mac's value
/// only), its baked images, its sandboxes, Uninstall.
async function viewRecipe(qualified) {
  const [report, data] = await Promise.all([api('settings'), api('recipes')]);
  adoptSettings(report);
  const r = data.recipes.find((x) => x.qualified === qualified);
  const crumbs = h('nav', { class: 'crumbs', 'aria-label': 'Where' }, h('a', { href: '#/settings' }, 'Settings'), icon('chevron-right'),
    h('a', { href: '#/settings/recipes' }, 'Recipes'), icon('chevron-right'), h('span', null, r ? r.title : qualified));
  if (!r) return h('div', { class: 'settings-page' }, crumbs, callout('warn', { cls: 'notice', title: 'No such recipe', body: qualified + ' is not in this Mac’s catalogue.' }));
  const stateWord = r.state === 'in use' ? 'In use' : r.state === 'installed' ? (r.notInstalled ? 'Not installed (your settings)' : 'Installed') : 'Available';
  const facts = h('div', { class: 'recipe-facts' },
    h('span', { class: 'tag ' + (r.state === 'in use' ? 'ok' : r.state === 'installed' && !r.notInstalled ? 'info' : 'outline'), 'data-recipe-state': r.state }, stateWord),
    h('span', { class: 'tag outline' }, r.source), r.isDefault ? h('span', { class: 'tag info' }, '★ your default image’s agent') : null,
    r.published ? null : h('span', { class: 'tag' }, 'unpublished'));
  const old = r.settings.flatMap((s) => s.aliases || []);
  const uninstall = r.images.length || r.settings.some((s) => s.source === 'mac')
    ? btn('Uninstall…', () => uninstallDialog(r), { small: true, icon: 'trash-2', title: r.uninstallRefusal || 'Remove its baked images from this Mac' }) : null;
  if (uninstall && r.uninstallRefusal) uninstall.disabled = true;
  // The crumbs and the head are the page's title bar together (components/page-title.js sticks the h1's top wrapper).
  return h('div', { class: 'settings-page recipe-page', 'data-recipe-page': r.qualified },
    h('div', { class: 'recipe-top' }, crumbs, h('div', { class: 'recipe-head' }, mark(r.icon, 'recipe-mark lg'),
      h('div', { class: 'recipe-title' }, h('h1', null, r.title), h('span', { class: 'recipe-q' }, r.qualified + ' · ' + r.subject)), uninstall)),
    facts,
    r.uninstallRefusal ? h('p', { class: 'muted' }, 'Uninstall: ' + r.uninstallRefusal + '.') : null,
    h('p', { class: 'sub' }, r.title + '’s settings on this Mac, from its recipe (', h('code', null, '[' + r.section + ']'),
      ' in doz.toml). A project or one sandbox can set its own; every value says where it came from.',
      old.length ? h('span', null, ' They used to be ', ...old.flatMap((o, i) => [i ? ', ' : '', h('code', null, o)]), ': those names still work.') : null),
    sourceLegend(),
    h('div', { class: 'panel settings' }, r.settings.map(settingRow)),
    h('h2', { class: 'set-head' }, 'Its baked images'),
    r.images.length
      ? h('div', { class: 'panel' }, h('div', { class: 'recipe-list' }, r.images.map((im) => h('div', { class: 'recipe-line' }, h('code', null, im.name), h('span', { class: 'muted' }, bytes(im.allocatedBytes))))))
      : h('p', { class: 'muted' }, 'None on this Mac — the first sandbox of it bakes one (Try, or New sandbox).'),
    h('h2', { class: 'set-head' }, 'Its sandboxes'),
    r.sandboxes.length
      ? h('div', { class: 'panel' }, h('div', { class: 'recipe-list' }, r.sandboxes.map((n) => h('div', { class: 'recipe-line' }, h('a', { href: '#/sandbox/' + n }, n),
          h('span', { class: 'muted' }, 'its own values: its page › Config')))))
      : h('p', { class: 'muted' }, 'None.'),
    h('h2', { class: 'set-head' }, 'In a terminal'),
    h('div', { class: 'panel' }, h('div', { class: 'panel-body recipe-cmds' }, h('code', null, 'doz config show --agent ' + r.qualified),
      h('code', null, 'doz config set --agent ' + r.id + ' NAME VALUE'), h('code', null, 'doz recipe uninstall ' + r.qualified))));
}
/// 669 (item 16): Uninstall — its baked images through Resources' own deletion (`resources-rm`), its settings kept unless
/// the box says forget them (each reset on this Mac). Refused while a sandbox runs it (the button is disabled, saying why).
function uninstallDialog(r) {
  const set = r.settings.filter((s) => s.source === 'mac');
  const what = r.images.length ? 'Its ' + plural(r.images.length, 'baked image', 'baked images') + ' (' + bytes(r.imageBytes) + ') are deleted; the next sandbox of it bakes one again.' : 'It has no baked image.';
  const fields = set.length ? [{ name: 'forget', type: 'checkbox', label: 'Also forget my settings for it on this Mac (' + set.map((s) => s.name).join(', ') + ')', value: false }] : [];
  dialog('Uninstall ' + r.title, what + ' Its sandboxes: none. Without the box below, your settings for it stay, and it is listed as not installed.', fields, 'Uninstall',
    async (v) => {
      if (r.uninstallIDs.length) await actOrThrow({ action: 'resources-rm', ids: r.uninstallIDs });
      if (v.forget) for (const s of set) await resetSetting(s.key);
      toast(r.title + ' uninstalled' + (v.forget ? ', its settings forgotten' : ''), false);
      refresh(false);
    }, { danger: true, confirmCheck: 'Yes, uninstall ' + r.qualified, icon: 'trash-2' });
}
function settingControl(r) {
  // 599c: the projects folder — chosen in the Mac's own folder picker (the server writes what was chosen;
  // the page never sends a path). Not when the environment or the command line sets it.
  if (r.key === 'defaults.projects_dir' && r.source !== 'env' && r.source !== 'flag') {
    const choose = btn('Choose…', () => chooseProjectsDir(), { small: true, icon: 'folder', title: 'Pick the folder in this Mac’s folder picker' });
    choose.dataset.projectsChoose = '';
    return h('div', { class: 'path-setting' }, h('code', { class: 'setting-value', 'data-projects-dir': '' }, shownValue(r.value, r.type)), isRemote() ? null : choose);
  }
  if (!r.editable) return h('code', { class: 'setting-value', title: r.note || '' }, shownValue(r.value, r.type));
  if (r.key === 'ui.density') return densityControl(r);
  if (r.key === 'ui.notifications') return notificationsControl(r);
  let input;
  if (r.type === 'bool') {
    input = h('input', { type: 'checkbox', role: 'switch', 'aria-label': r.key });
    input.checked = r.value === true;
    input.addEventListener('change', () => changeSetting(r.key, input.checked));
  } else if (r.type === 'choice') {
    input = h('select', { 'aria-label': r.key }, r.choices.map((c) => {
      const o = h('option', { value: c }, c);
      if (c === r.value) o.selected = true;
      return o;
    }));
    input.addEventListener('change', () => changeSetting(r.key, input.value));
  } else if (r.type === 'permissions') {
    // 597 (P4): the default permissions of new sandboxes — the same switches (on a base with no
    // language of its own; a base's ecosystem joins Standard for it), saved as words on Standard.
    input = h('div', { class: 'perm-setting', 'data-perm-setting': '' }, h('span', { class: 'muted' }, '…'));
    api('bases').then((b) => {
      const std = new Set(b.standard[''] || []);
      let on = new Set(b.defaults[''] || []);
      const all = b.permissions.map((x) => x.id).filter((x) => !isAgentModel(x));
      const words = () => {
        const same = (a, c) => a.size === c.size && [...a].every((x) => c.has(x));
        if (same(on, std)) return 'standard';
        if (same(on, new Set(['model']))) return 'locked';
        if (same(on, new Set(all.filter((x) => !x.startsWith('github:'))))) return 'open';   // Open never includes your GitHub login
        return [...all.filter((x) => on.has(x) && !std.has(x)).map((x) => '+' + x), ...all.filter((x) => !on.has(x) && std.has(x)).map((x) => '-' + x)].join(',');
      };
      const paint = () => input.replaceChildren(h('code', { 'data-perm-words': '' }, words()),
        permissionSwitches(b.permissions, on, (id, v) => {
          const apply = () => {
            const inst = b.permissions.filter((x) => x.group === 'install').map((x) => x.id);
            for (const x of id === 'install' ? inst : [id]) { if (v) on.add(x); else on.delete(x); }
            changeSetting(r.key, words());
          };
          if (id === 'web' && v) confirmWeb(async () => apply()); else apply();
        }, { hosts: false }));
      paint();
    }).catch(() => input.replaceChildren(h('code', null, String(r.value))));
  } else if (r.type === 'int') {
    input = h('input', { type: 'number', min: String(r.min), max: String(r.max), step: '1', 'aria-label': r.key });
    input.value = String(r.value);
    input.addEventListener('change', () => {
      const n = Number(input.value);
      if (!isInt(n, r.min, r.max)) { settingFailed(r.key, r.key + ' is a whole number, ' + r.min + '–' + r.max); input.value = String(r.value); return; }
      changeSetting(r.key, n);
    });
  } else {
    // The open-files bridge's app list is names, comma-separated (empty: only each file's default app).
    // Dotfiles from here are a repository's URL (a folder on the Mac is set on the Mac: doz config set).
    const placeholder = r.type === 'apps' ? 'e.g. Typora, Visual Studio Code (empty: default apps only)'
      : r.type === 'dotfiles' ? 'your dotfiles repository’s https address (empty: none)' : '"" = automatic';
    input = h('input', { type: 'text', spellcheck: 'false', autocomplete: 'off', 'aria-label': r.key, placeholder });
    input.value = String(r.value);
    input.addEventListener('change', () => changeSetting(r.key, input.value.trim()));
  }
  return input;
}
/// 647: ui.density as a segmented control (Comfortable | Compact) — applied to the page at once, then saved (the theme
/// switch's way); a failed save puts the page back and says so in the row.
function densityControl(r) {
  const words = { comfortable: 'Comfortable', compact: 'Compact' };
  const seg = h('div', { class: 'segmented', role: 'group', 'aria-label': r.key, 'data-density-control': '' },
    r.choices.map((c) => {
      const on = c === r.value;
      return h('button', { type: 'button', class: 'seg' + (on ? ' active' : ''), 'aria-pressed': on ? 'true' : 'false', 'data-density-choice': c,
        on: { click: () => {
          if (c === setting('ui.density', 'comfortable')) return;
          for (const b of seg.querySelectorAll('.seg')) { const me = b.dataset.densityChoice === c; b.classList.toggle('active', me); b.setAttribute('aria-pressed', me ? 'true' : 'false'); }
          applyDensity(c);
          changeSetting(r.key, c).then(() => applyDensity(setting('ui.density', 'comfortable')));
        } } }, words[c] || c);
    }));
  return seg;
}
/// 647: ui.notifications as a segmented control (Cards | Pills | Bell) — the header's notifications follow at once
/// (adoptSettings repaints them when the save returns).
function notificationsControl(r) {
  const words = { cards: 'Cards', pills: 'Pills', bell: 'Bell' };
  const seg = h('div', { class: 'segmented', role: 'group', 'aria-label': r.key, 'data-notes-control': '' },
    r.choices.map((c) => {
      const on = c === r.value;
      return h('button', { type: 'button', class: 'seg' + (on ? ' active' : ''), 'aria-pressed': on ? 'true' : 'false', 'data-notes-choice': c,
        on: { click: () => {
          if (c === setting('ui.notifications', 'cards')) return;
          for (const b of seg.querySelectorAll('.seg')) { const me = b.dataset.notesChoice === c; b.classList.toggle('active', me); b.setAttribute('aria-pressed', me ? 'true' : 'false'); }
          changeSetting(r.key, c);
        } } }, words[c] || c);
    }));
  return seg;
}
/// 603: a setting that could not be changed says so in its own row (kept across the page's re-render).
state.settingErr = new Map();
function settingFailed(key, text) {
  state.settingErr.set(key, text);
  const row = document.querySelector('.setting[data-key="' + CSS.escape(key) + '"]');
  if (row) paintSettingError(row, key); else pageFailure(text);
}
function paintSettingError(row, key) {
  row.querySelector('.setting-error')?.remove();
  const text = state.settingErr.get(key);
  if (text) row.querySelector('.setting-main').append(callout('bad', { compact: true, cls: 'setting-error', body: text,
    dismiss: () => { state.settingErr.delete(key); paintSettingError(row, key); } }));
}
async function chooseProjectsDir() {
  try {
    const c = await api('settings/projects-dir/choose', { method: 'POST', json: {} });
    if (c.cancelled) return;
    adoptSettings(c.report);
    state.settingErr.delete('defaults.projects_dir');
    toast('defaults.projects_dir saved: ' + c.path, false);
  } catch (e) {
    settingFailed('defaults.projects_dir', e.message || String(e));
  }
  refresh(false);
}
async function changeSetting(key, value) {
  try {
    if (value === null) await resetSetting(key); else await saveSetting(key, value);
    state.settingErr.delete(key);
    toast(key + (value === null ? ' is the default again' : ' saved'), false);
  } catch (e) {
    settingFailed(key, e.message || String(e));
  }
  refresh(false);
}
