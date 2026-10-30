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
import { btn } from '../components/button.js';
import { callout } from '../components/callout.js';
import { pageFailure, toast } from '../components/notices.js';
import { confirmWeb, isAgentModel, permissionSwitches } from '../components/permissions.js';
import { dialog } from '../components/dialog.js';
import { sourceBadge, sourceLegend, sourceTag } from '../components/setting-source.js';
import { settingMatrix } from '../components/setting-matrix.js';
import { mark } from '../dom/icons.js';
import { bytes, plural } from '../core/format.js';
import { actOrThrow } from '../core/operations.js';

const SETTING_SECTIONS = {
  ui: 'This UI', host: 'The host', store: 'The store', defaults: 'New sandboxes', agent: 'The agent', sandbox: 'Inside every sandbox',
  'images.lab': 'New lab sandboxes', kernel: 'The kernel',
  resources: 'Resources', sessions: 'Sessions', bridges: 'Bridges', workspace: 'Workspace rules', github: 'GitHub', images: 'Images', telemetry: 'Usage statistics',
  updates: 'Updates', serve: 'Other devices (LAN)',
};
// An empty app list (or dotfiles) means none, not "automatic".
function shownValue(v, type) { return typeof v === 'string' ? (v === '' ? (type === 'apps' || type === 'dotfiles' ? '""  (none)' : '""  (automatic)') : v) : String(v); }
/// 669 (owner: "move it to the left nav"): the Recipes page (#/recipes) and a recipe's own (#/recipes/V/P).
export async function viewRecipes() {
  if (state.recipe) return viewRecipe(state.recipe);
  const [report, recipes] = await Promise.all([api('settings'), api('recipes').catch(() => null)]);
  adoptSettings(report);
  return h('div', { class: 'settings-page recipes-page' }, h('h1', null, 'Recipes'), recipesSection(recipes), sourceLegend());
}
/// 669 (owner: "redo the entire layout of Settings to be how VSCode does it … and make the section navigation to the left
/// only when there is enough width"): the search across the top (sticky under the title), then the sections' table of
/// contents on the left — only when the PAGE (not the window: the sidebar may be a rail or not) is at least SETTINGS_WIDE
/// wide, `.is-wide` on the page set by a ResizeObserver — and the settings, each a block: its title, its description, its
/// control under them. Narrower, no table of contents at all.
const SETTINGS_WIDE = 960;
let settingsWasWide = false;   // the last page's answer, so a re-render starts with it (no flash before the observer)
export async function viewSettings() {
  adoptSettings(await api('settings'));
  const rep = state.settings.report;
  const sections = [];
  // 669: a recipe's settings are on its own page (Recipes, in the sidebar), never in Dozable's sections.
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
  // 603 (E13): a search over what the page already has (a key, a name, a section, a description); 669: across the top.
  const filter = h('input', { type: 'search', class: 'page-filter', 'data-settings-filter': '', placeholder: 'Search settings — a key like ui.theme, or a word',
    'aria-label': 'Search the settings', autocomplete: 'off', spellcheck: 'false' });
  filter.value = state.settingsFilter || '';
  const secId = (name) => 'set-' + name.replace(/[^a-z0-9]+/gi, '-');
  const label = (name) => SETTING_SECTIONS[name] || name;
  // The sections in page order: Access, Dozable's, then what is not settable. Each [id, title, its block's content, the
  // words a search of the section itself matches].
  const secs = [
    ['access', 'Access', [
      h('p', { class: 'sub' }, 'What sandboxes may use as you. Change a choice in the settings below (',
        h('code', null, 'defaults.github'), ', ', h('code', null, 'github.credentials'), ', ', h('code', null, 'sandbox.ssh_agent'),
        ') or with ', h('code', null, 'doz access set'), '; the Claude account on the Accounts page.'),
      accessBox], 'access credentials'],
    ...sections.map((sec) => [secId(sec.name), label(sec.name),
      [h('div', { class: 'settings set-rows', 'data-section': sec.name }, sec.rows.map((r) => settingRow(r, { prefix: label(sec.name) })))], null, sec.name]),
    ['set-not-settable', 'Not settable', [h('ul', { class: 'plain set-plain' }, rep.notSettable.map((n) => h('li', null, n)))],
      'not settable by design ' + rep.notSettable.join(' ').toLowerCase(), 'not-settable'],
  ];
  const blocks = secs.map(([id, title, body, words, section]) => h('section', { class: 'set-sec', 'data-sec': id, 'data-section': section || null, 'data-words': words || null },
    h('h2', { id, class: 'set-head' }, title, section && section !== 'not-settable' ? h('code', { class: 'set-head-key' }, '[' + section + ']') : null), body));
  // The table of contents: a link per section; the one in view is marked (bold + the indicator, as the sidebar's).
  const toc = h('nav', { class: 'set-toc', 'aria-label': 'Sections' }, secs.map(([id, title]) =>
    h('a', { href: '#' + (location.hash.slice(1) || '/'), 'data-toc': id, on: { click: (ev) => { ev.preventDefault(); goTo(id); } } }, title)));
  const none = h('p', { class: 'muted filter-none', 'data-filter-none': '', hidden: true }, 'No setting matches.');
  const node = h('div', { class: 'settings-page vs-settings' + (settingsWasWide ? ' is-wide' : ''), 'data-settings-page': '' }, h('h1', null, 'Settings'),
    h('p', { class: 'sub set-sub' }, 'Written to ', h('code', null, rep.path || 'no file (neither XDG_CONFIG_HOME nor HOME is set)'),
      rep.exists ? '' : ' — not written yet: the first change writes it, with every setting listed at its default',
      '. A flag wins, then the environment, a sandbox’s own value, its project’s (', h('code', null, 'doz_project.yaml'),
      '), this Mac’s, then the default; ', h('code', null, 'doz config show'), ' prints the same. A recipe’s own settings are on its page: ',
      h('a', { href: '#/recipes' }, 'Recipes'), '.'),
    sourceLegend(),
    rep.error ? callout('bad', { cls: 'notice', title: 'The settings file does not read', body: rep.error + ' — nothing in it applies, and the UI will not overwrite it. Fix it (or remove it) first.' }) : null,
    warnings.length ? callout('warn', { cls: 'notice', body: h('ul', { class: 'plain' }, warnings.map((w) => h('li', null, w))) }) : null,
    h('div', { class: 'page-tools set-search' }, h('label', { class: 'filter-field' }, icon('search'), filter)),
    h('div', { class: 'set-body' }, toc, h('div', { class: 'set-list' }, none, blocks)));
  let pinned = null;     // the section a click chose — kept while it is on screen (a short last section never reaches the top)
  let shownOnce = false; // the node is built before the router inserts it: only a node that WAS on the page is gone for good
  const mark = (id) => { for (const a of toc.querySelectorAll('a[data-toc]')) a.classList.toggle('is-current', a.dataset.toc === id); };
  const current = () => {
    if (!node.isConnected) { if (shownOnce) window.removeEventListener('scroll', current); return; }
    shownOnce = true;
    if (!node.classList.contains('is-wide')) return;
    const shown = blocks.filter((b) => !b.hidden);
    if (pinned) {
      const b = shown.find((x) => x.dataset.sec === pinned), r = b && b.getBoundingClientRect();
      if (r && r.top < window.innerHeight && r.bottom > 0) { mark(pinned); return; }
      pinned = null;
    }
    const line = node.querySelector('.set-search').getBoundingClientRect().bottom + 24;
    let at = shown[0];
    for (const b of shown) if (b.getBoundingClientRect().top <= line) at = b;
    mark(at ? at.dataset.sec : null);
  };
  function goTo(id) {
    const t = node.querySelector('#' + CSS.escape(id));
    if (!t) return;
    pinned = id;
    t.scrollIntoView({ block: 'start' });
    current();
  }
  window.addEventListener('scroll', current, { passive: true });
  const wide = new ResizeObserver(() => {
    if (!node.isConnected) { if (shownOnce) wide.disconnect(); return; }
    const w = node.getBoundingClientRect().width >= SETTINGS_WIDE;
    settingsWasWide = w;
    node.classList.toggle('is-wide', w);
    current();
  });
  wide.observe(node);
  const apply = () => {
    const q = filter.value.trim().toLowerCase();
    state.settingsFilter = filter.value;
    let any = false;
    for (const row of node.querySelectorAll('.setting[data-key]')) {
      const r = state.settings.byKey[row.dataset.key];
      const hit = !q || [r.key, r.name, humanName(r.name), r.description, r.section, label(r.section)].some((t) => String(t || '').toLowerCase().includes(q));
      row.hidden = !hit;
      any = any || hit;
    }
    // A section with no match stands aside, and so does its entry in the table of contents; Access and Not settable match
    // on their own words.
    for (const b of blocks) {
      const rows = [...b.querySelectorAll('.setting[data-key]')];
      const hit = !q || (rows.length ? rows.some((x) => !x.hidden) : String(b.dataset.words || '').includes(q));
      b.hidden = !hit;
      if (hit && !rows.length && q) any = true;
      const a = toc.querySelector('a[data-toc="' + b.dataset.sec + '"]');
      if (a) a.hidden = !hit;
    }
    none.hidden = !q || any;
    current();
  };
  filter.addEventListener('input', apply);
  filter.addEventListener('keydown', (ev) => { if (ev.key === 'Escape' && filter.value) { ev.stopPropagation(); filter.value = ''; apply(); } });
  apply();
  return node;
}
// 669: a setting's name as words — `confirm_shutdown` → "Confirm shutdown", `memory_mib` → "Memory (MiB)" (the key itself is
// shown beside it: the docs and `doz config set KEY` use keys).
const NAME_WORDS = { ui: 'UI', lan: 'LAN', cpus: 'CPUs', nat: 'NAT', ssh: 'SSH', mib: '(MiB)', ms: '(ms)', tmux: 'tmux', id: 'ID', url: 'URL' };
function humanName(name) {
  const parts = String(name).split(/[._]+/).filter(Boolean);
  if (!parts.length) return String(name);
  return parts.map((w, i) => NAME_WORDS[w] || (i === 0 ? w[0].toUpperCase() + w.slice(1) : w)).join(' ');
}
/// One setting as a block (669, like VS Code's): its title — the section as a prefix (on Settings), the name in bold, its
/// source badge, its key, and "Default" when this Mac sets it —, the description, then the control under them at a modest
/// width (a checkbox sits before the description instead); what it defaults to and when a change applies, muted. A value
/// this Mac, the environment or a flag sets is MODIFIED: a bar at the row's left (`.is-modified`).
function settingRow(r, opts = {}) {
  const source = sourceBadge(r);
  // 669: "Default" resets this Mac's value only (the file's line commented out).
  const reset = r.editable && (r.source === 'mac' || r.source === 'file')
    ? btn('Default', () => changeSetting(r.key, null), { small: true, quiet: true, icon: 'rotate-ccw', title: 'Comment it out in the file: the default (' + shownValue(r.defaultValue, r.type) + ') applies' }) : null;
  if (reset) reset.classList.add('set-reset');
  const modified = ['mac', 'file', 'env', 'flag'].includes(r.source);
  const checkbox = r.type === 'bool' && r.editable && r.key !== 'defaults.projects_dir';
  const cls = ['setting'];
  // 602: a control that is a block of its own (the permissions checklist) takes the column's whole width.
  if (r.type === 'permissions') cls.push('setting-wide');
  if (checkbox) cls.push('is-bool');
  if (modified) cls.push('is-modified');
  const inputId = 'setting-' + r.key.replace(/[^a-z0-9]+/gi, '-');
  const control = settingControl(r, inputId);
  const row = h('div', { class: cls.join(' '), 'data-key': r.key },
    h('div', { class: 'setting-main' },
      h('div', { class: 'setting-name' },
        h('span', { class: 'set-label' }, opts.prefix ? h('span', { class: 'set-cat' }, opts.prefix + ': ') : null, h('strong', { class: 'set-title' }, humanName(r.name))),
        source, h('code', { class: 'set-key', title: 'doz config set ' + r.key + ' VALUE' }, r.key), reset)),
    h('div', { class: 'setting-control' }, control),
    checkbox ? h('label', { class: 'set-desc', for: inputId }, r.description) : h('div', { class: 'set-desc' }, r.description),
    h('div', { class: 'muted setting-meta' }, 'default ', h('code', null, shownValue(r.defaultValue, r.type)), ' · ', r.appliesNote,
      r.note ? h('div', null, r.note) : null));
  if (state.settingErr.has(r.key)) paintSettingError(row, r.key);
  return row;
}
// ── 669: Recipes (659 §0; owner: its own place in the sidebar, beside Quick try) ──
// The recipes on this Mac, grouped by state: In use (a sandbox runs its agent), then Installed (a baked image of it, or
// this Mac's values with none: "not installed"). The rest of the catalogue is Recipes › Browse (#/browse). A row
// opens the recipe's page (#/recipes/V/P): its settings, its baked images, its sandboxes, Uninstall.
function recipeHash(r) { return '#/recipes/' + r.qualified; }
function shown(v) { return typeof v === 'string' ? (v === '' ? '""' : v) : String(v); }
function recipeRow(r, withState) {
  const set = r.settings.filter((s) => s.source === 'mac');
  const meta = [];
  if (r.state === 'in use') meta.push(plural(r.sandboxes.length, 'sandbox', 'sandboxes') + ' · ' + r.sandboxes.slice(0, 3).join(', ') + (r.sandboxes.length > 3 ? ', …' : ''));
  if (r.images.length) meta.push(plural(r.images.length, 'baked image', 'baked images') + ' · ' + bytes(r.imageBytes));
  else if (r.state !== 'available') meta.push('no baked image');
  if (r.state === 'available') meta.push('in the catalogue');
  const tags = [h('span', { class: 'tag outline' }, r.source)];
  // Browse: one on this Mac says so.
  if (withState && r.state !== 'available') tags.unshift(h('span', { class: 'tag ' + (r.state === 'in use' ? 'ok' : 'info'), 'data-recipe-state': r.state }, r.state === 'in use' ? 'in use' : 'installed'));
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
    box.append(callout('warn', { cls: 'notice', body: 'The recipes could not be read.' }));
    return box;
  }
  const all = data.recipes;
  const inUse = all.filter((r) => r.state === 'in use'), installed = all.filter((r) => r.state === 'installed');
  const available = all.filter((r) => r.state === 'available');
  const group = (title, rows, empty) => [h('div', { class: 'recipe-group' }, title + ' · ' + rows.length),
    rows.length ? h('div', { class: 'recipe-list' }, rows.map((r) => recipeRow(r, false))) : h('div', { class: 'recipe-empty muted' }, empty)];
  box.append(
    h('p', { class: 'sub' }, 'The recipes on this Mac: in use (a sandbox runs its agent) and installed (a baked image of it). A recipe’s settings come with it (',
      h('code', null, '[recipes.*]'), ' in doz.toml); open one to change them on this Mac, see its baked images and its sandboxes, or uninstall it. A project (',
      h('code', null, 'approvals:'), ' in doz_project.yaml) or one sandbox can set its own. ', h('a', { href: '#/try' }, 'Quick try'), ' makes a sandbox of any recipe.'),
    h('div', { class: 'panel recipes-panel' },
      group('In use', inUse, 'No sandbox runs a recipe’s agent.'),
      group('Installed', installed, 'No other recipe has a baked image on this Mac.'),
      h('div', { class: 'recipe-empty muted' }, plural(available.length, 'more recipe', 'more recipes') + ' in the catalogue — ', h('a', { href: '#/browse' }, 'Browse'), '.')));
  return box;
}
/// 669 (owner: "move the recipe Browser … to its own page Recipes > Browse"): every recipe of the catalogue, searched by
/// its name, full name, id or subject; one on this Mac says so. A row opens the recipe's page.
export async function viewBrowse() {
  const data = await api('recipes').catch(() => null);
  if (!data) return h('div', { class: 'settings-page recipes-page' }, h('h1', null, 'Browse recipes'), callout('warn', { cls: 'notice', body: 'The recipes could not be read.' }));
  const all = [...data.recipes].sort((a, b) => a.title.localeCompare(b.title));
  const list = h('div', { class: 'recipe-list' });
  const count = h('div', { class: 'recipe-group' });
  const search = h('input', { type: 'search', class: 'page-filter', 'data-recipe-catalogue': '', placeholder: 'Search recipes — a name, a vendor, what it is',
    'aria-label': 'Search the recipes', autocomplete: 'off', spellcheck: 'false' });
  search.value = state.recipeQuery;
  const paint = () => {
    const q = state.recipeQuery.trim().toLowerCase();
    const found = q ? all.filter((r) => [r.title, r.qualified, r.id, r.subject].join(' ').toLowerCase().includes(q)) : all;
    count.textContent = (q ? 'Matching “' + q + '”' : 'Every recipe') + ' · ' + found.length;
    list.replaceChildren(...(found.length ? found.map((r) => recipeRow(r, true)) : [h('div', { class: 'recipe-empty muted' }, 'No recipe matches.')]));
  };
  search.addEventListener('input', () => { state.recipeQuery = search.value; paint(); });
  paint();
  return h('div', { class: 'settings-page recipes-page', 'data-recipe-browse': '' }, h('h1', null, 'Browse recipes'),
    h('p', { class: 'sub' }, 'Every recipe in the catalogue. Open one to see what it installs and its settings; ', h('a', { href: '#/try' }, 'Quick try'), ' makes a sandbox of it.'),
    h('div', { class: 'page-tools' }, h('label', { class: 'filter-field' }, icon('search'), search)),
    h('div', { class: 'panel recipes-panel' }, count, list));
}
/// 669 (item 12): one recipe's page — its state, its settings (each with its badge; "Default" resets this Mac's value
/// only), its baked images, its sandboxes, Uninstall.
async function viewRecipe(qualified) {
  const [report, data] = await Promise.all([api('settings'), api('recipes')]);
  adoptSettings(report);
  const r = data.recipes.find((x) => x.qualified === qualified);
  // An available recipe (reached from Browse) leads back to Browse; one on this Mac to Installed.
  const back = !r || r.state === 'available' ? ['#/browse', 'Browse'] : ['#/recipes', 'Installed'];
  const crumbs = h('nav', { class: 'crumbs', 'aria-label': 'Where' }, h('span', null, 'Recipes'), icon('chevron-right'),
    h('a', { href: back[0] }, back[1]), icon('chevron-right'), h('span', null, r ? r.title : qualified));
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
    h('div', { class: 'panel settings' }, r.settings.map((s) => settingRow(s))),
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
  const what = r.images.length === 1 ? 'Its baked image (' + bytes(r.imageBytes) + ') is deleted; the next sandbox of it bakes one again.'
    : r.images.length ? 'Its ' + r.images.length + ' baked images (' + bytes(r.imageBytes) + ') are deleted; the next sandbox of it bakes one again.' : 'It has no baked image.';
  const fields = set.length ? [{ name: 'forget', type: 'checkbox', label: 'Also forget my settings for it on this Mac (' + set.map((s) => s.name).join(', ') + ')', value: false }] : [];
  dialog('Uninstall ' + r.title, what + ' Its sandboxes: none. Without the box below, your settings for it stay, and it is listed as not installed.', fields, 'Uninstall',
    async (v) => {
      if (r.uninstallIDs.length) await actOrThrow({ action: 'resources-rm', ids: r.uninstallIDs });
      if (v.forget) for (const s of set) await resetSetting(s.key);
      toast(r.title + ' uninstalled' + (v.forget ? ', its settings forgotten' : ''), false);
      refresh(false);
    }, { danger: true, confirmCheck: 'Yes, uninstall ' + r.qualified, icon: 'trash-2' });
}
function settingControl(r, inputId) {
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
    // 669: a checkbox before the description (VS Code's), the description its label.
    input = h('input', { type: 'checkbox', id: inputId || null, 'aria-label': r.key });
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
    input = permissionsControl(r);
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
/// 597 (P4) → 669 (owner: VS Code's "Type Checking Mode"): the default permissions of new sandboxes as a MATRIX — the shared
/// permissions down, Locked · Standard · Open across (Custom too when the value is one), a tick where the preset includes
/// it, the current column marked — then the drop-down that picks the preset. Custom shows the switches (on a base with no
/// language of its own; a base's ecosystem joins Standard for it), saved as words on Standard. The presets here are the
/// ones the saved words are computed from, so the matrix and the words always agree.
const customOpen = new Set();   // the keys whose switches the person opened with Custom (kept across the page's re-render)
function permissionsControl(r) {
  const box = h('div', { class: 'perm-setting', 'data-perm-setting': '' }, h('span', { class: 'muted' }, '…'));
  api('bases').then((b) => {
    const perms = b.permissions.filter((x) => !isAgentModel(x.id));
    const all = perms.map((x) => x.id);
    const on = new Set(b.defaults[''] || []);
    const PRESETS = {
      standard: new Set(b.standard[''] || []),
      locked: new Set(['model']),
      open: new Set(all.filter((x) => !x.startsWith('github:'))),   // Open never includes your GitHub login
    };
    const std = PRESETS.standard;
    const same = (a, c) => a.size === c.size && [...a].every((x) => c.has(x));
    const presetOf = (s) => Object.keys(PRESETS).find((k) => same(s, PRESETS[k])) || null;
    const words = () => presetOf(on)
      || [...all.filter((x) => on.has(x) && !std.has(x)).map((x) => '+' + x), ...all.filter((x) => !on.has(x) && std.has(x)).map((x) => '-' + x)].join(',');
    // The matrix's rows: each shared permission, but the languages' packages as ONE row (system packages keep their own:
    // Standard has them).
    const langs = perms.filter((x) => x.group === 'install' && x.id !== 'install:system');
    const rows = [];
    for (const p of perms) {
      if (p.id === 'install:system') rows.push({ id: p.id, title: 'Install system packages', note: 'apt / apk', ids: [p.id] });
      else if (p.group === 'install') {
        if (p === langs[0]) rows.push({ id: 'install', title: 'Install language packages', note: langs.map((x) => x.title).join(' · '), ids: langs.map((x) => x.id) });
      } else rows.push({ id: p.id, title: p.title, ids: [p.id] });
    }
    for (const row of rows) row.attrs = { 'data-perm-row': row.id };
    const paint = () => {
      const now = presetOf(on) || 'custom';
      const sets = { ...PRESETS, custom: on };
      const columns = [{ id: 'locked', title: 'Locked' }, { id: 'standard', title: 'Standard' }, { id: 'open', title: 'Open' }];
      if (now === 'custom') columns.push({ id: 'custom', title: 'Custom' });
      const matrix = settingMatrix({ label: 'What each preset lets the agent do', rows, columns, current: now,
        cell: (row, col) => {
          const n = row.ids.filter((x) => sets[col.id].has(x)).length;
          return n === row.ids.length ? true : n ? n + ' of ' + row.ids.length : false;
        } });
      const custom = now === 'custom' || customOpen.has(r.key);
      const sel = h('select', { 'aria-label': r.key, 'data-perm-preset': '' },
        [['locked', 'Locked'], ['standard', 'Standard'], ['open', 'Open'], ['custom', 'Custom']].map(([v, l]) => h('option', { value: v }, l)));
      sel.value = custom ? 'custom' : now;
      sel.addEventListener('change', () => {
        const v = sel.value;
        if (v === 'custom') { customOpen.add(r.key); paint(); return; }
        if (v === now) { customOpen.delete(r.key); paint(); return; }
        if (v === 'open') {
          // Open lets the agent browse the web: asked first; a Cancel puts the drop-down back.
          let ok = false;
          confirmWeb(async () => { ok = true; customOpen.delete(r.key); await changeSetting(r.key, 'open'); })
            .addEventListener('close', () => { if (!ok) paint(); });
          return;
        }
        customOpen.delete(r.key);
        changeSetting(r.key, v);
      });
      // (never a null into replaceChildren: the DOM writes it as the text "null")
      box.replaceChildren(...[matrix,
        h('p', { class: 'muted perm-matrix-note' }, 'A base’s own language packages (pip on a Python base, npm on a Node one) join Standard for that base. ',
          'Use GitHub as you and Push to GitHub are in no preset: choose them in Custom, or per sandbox.'),
        h('div', { class: 'perm-preset' }, sel, h('span', { class: 'muted' }, 'saved as ', h('code', { 'data-perm-words': '' }, words()))),
        custom ? permissionSwitches(b.permissions, on, (id, v) => {
          const apply = () => {
            const inst = b.permissions.filter((x) => x.group === 'install').map((x) => x.id);
            for (const x of id === 'install' ? inst : [id]) { if (v) on.add(x); else on.delete(x); }
            changeSetting(r.key, words());
          };
          if (id === 'web' && v) confirmWeb(async () => apply()); else apply();
        }, { hosts: false }) : null].filter(Boolean));
    };
    paint();
  }).catch(() => box.replaceChildren(h('code', null, String(r.value))));
  return box;
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
  if (text) row.append(callout('bad', { compact: true, cls: 'setting-error', body: text,
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
  if (value === null) customOpen.delete(key);   // Default: back to the preset, the switches put away
  try {
    if (value === null) await resetSetting(key); else await saveSetting(key, value);
    state.settingErr.delete(key);
    toast(key + (value === null ? ' is the default again' : ' saved'), false);
  } catch (e) {
    settingFailed(key, e.message || String(e));
  }
  refresh(false);
}
