// core/routes — The page's addresses: what a hash names (`parse`), and the old addresses that lead to today's (`canonical`,
// `LEGACY`). Pure: no DOM, no state. The router replaces an old address with its canonical one first, then parses.
//
// Today's addresses: #/home · #/chat[/ROOM] · #/bots · #/sandbox/NAME[/SESSION|~home] · #/mac (This Mac) and its pages,
// #/mac/here[/SESSION] (the sessions on this Mac), #/mac/sessions, #/mac/sandboxes, #/mac/loose, #/mac/macs (Your Macs), #/mac/templates[/browse |
// /V/P], #/mac/images, accounts, resources, devices, doctor, settings, debug, #/mac/logs/<operations|activity|notifications|
// metrics> · the modals #/new, #/onboarding, #/try[/AGENT].

/// The words after #/mac/ that name a page of This Mac (a session on this Mac named like one loses its old deep link).
export const MAC_RESERVED = ['here', 'sessions', 'sandboxes', 'loose', 'templates', 'images', 'accounts', 'resources', 'devices', 'logs',
  'doctor', 'settings', 'debug', 'macs'];
/// This Mac's pages whose view keeps its old name (#/mac/images → view `images`).
const MAC_SAME = ['images', 'accounts', 'resources', 'devices', 'doctor', 'settings', 'debug'];
/// This Mac › Logs.
export const LOG_PAGES = ['operations', 'activity', 'notifications', 'metrics'];
/// The modals over the page.
export const MODAL_VIEWS = new Set(['new', 'onboarding', 'try']);
/// The page an empty or unknown address opens.
export const HOME = '#/home';

const RECIPE = '[a-z0-9-]{1,40}(?:/[a-z0-9-]{1,40}){1,2}';
const MAC_SESSION = '[A-Za-z0-9_-][A-Za-z0-9._-]{0,31}';

/// Every old address and where it leads now: [pattern, replacement] — the replacement a string (`$1` the first group) or
/// a function of the match. The only place an old address is written.
export const LEGACY = [
  [/^#\/settings\/recipes(\/.*)?$/, (m) => '#/mac/templates' + (m[1] || '')],
  [/^#\/recipes(\/.*)?$/, (m) => '#/mac/templates' + (m[1] || '')],
  [/^#\/browse$/, () => '#/mac/templates/browse'],
  [/^#\/overview$/, () => '#/mac/sandboxes'],
  [/^#\/sandbox\/?$/, () => '#/mac/sandboxes'],
  [/^#\/(?:sessions|terminals)$/, () => '#/mac/sessions'],
  [new RegExp('^#/(' + MAC_SAME.join('|') + ')$'), (m) => '#/mac/' + m[1]],
  [new RegExp('^#/(' + LOG_PAGES.join('|') + ')$'), (m) => '#/mac/logs/' + m[1]],
  [/^#\/mac\/logs\/?$/, () => '#/mac/logs/operations'],
  [/^#\/general$/, () => '#/chat'],
  [/^#\/needs-you$/, () => HOME],
  [/^#\/?$/, () => HOME],
  [/^$/, () => HOME],
];

/// The canonical address for `hash`: itself when it already is one, its new address when it is an old one, else Home.
export function canonical(hash) {
  const h = hash || '';
  // #/mac/SESSION (before This Mac's pages had addresses) → #/mac/here/SESSION, unless SESSION is a page's word.
  const old = new RegExp('^#/mac/(' + MAC_SESSION + ')$').exec(h);
  if (old && !MAC_RESERVED.includes(old[1])) return '#/mac/here/' + old[1];
  if (parse(h)) return h;
  for (const [re, to] of LEGACY) {
    const m = re.exec(h);
    if (m) { const c = to(m); return parse(c) ? c : HOME; }
  }
  return HOME;
}

/// What a canonical address names: {view, param, session, recipe, modal} (null: not an address of the page).
/// `view` is the page's view name (`state.view`); `recipe` is '' for the templates' list, 'V/P' for one, null otherwise.
export function parse(hash) {
  const r = (view, o = {}) => ({ view, param: o.param || null, session: o.session || null, recipe: o.recipe === undefined ? null : o.recipe,
    modal: !!o.modal });
  let m;
  if (hash === '#/home') return r('home');
  if (hash === '#/bots') return r('bots');
  if (hash === '#/mac') return r('thismac');
  if ((m = new RegExp('^#/mac/here(?:/(' + MAC_SESSION + '))?$').exec(hash))) return r('mac', { session: m[1] });
  if (hash === '#/mac/sessions') return r('sessions');
  if (hash === '#/mac/sandboxes') return r('overview');
  if (hash === '#/mac/loose') return r('loose');
  if (hash === '#/mac/macs') return r('macs');
  if (hash === '#/mac/templates') return r('recipes', { recipe: '' });
  if (hash === '#/mac/templates/browse') return r('browse');
  if ((m = new RegExp('^#/mac/templates/(' + RECIPE + ')$').exec(hash))) return r('recipes', { recipe: m[1] });
  if ((m = new RegExp('^#/mac/(' + MAC_SAME.join('|') + ')$').exec(hash))) return r(m[1]);
  if ((m = new RegExp('^#/mac/logs/(' + LOG_PAGES.join('|') + ')$').exec(hash))) return r(m[1]);
  if ((m = /^#\/chat(?:\/([a-z0-9][a-z0-9_-]{0,63}))?$/.exec(hash))) return r('chat', { param: m[1] });
  // 635: `~home` (no session name can hold a ~) selects a sandbox page's Home tab.
  if ((m = /^#\/sandbox\/([a-z0-9-]{1,40})(?:\/(~home|[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}))?$/.exec(hash))) return r('sandbox', { param: m[1], session: m[2] });
  if (hash === '#/new' || hash === '#/onboarding') return r(hash.slice(2), { modal: true });
  if ((m = /^#\/try(?:\/([a-z0-9-]{1,40}))?$/.exec(hash))) return r('try', { param: m[1], modal: true });
  return null;
}

/// The address of a view with no parameter (the sidebar's and a link's): `hashFor('images')` → '#/mac/images'.
export function hashFor(view) {
  if (view === 'home' || view === 'bots') return '#/' + view;
  if (view === 'thismac') return '#/mac';
  if (view === 'mac') return '#/mac/here';
  if (view === 'sessions' || view === 'loose' || view === 'macs') return '#/mac/' + view;
  if (view === 'overview') return '#/mac/sandboxes';
  if (view === 'recipes') return '#/mac/templates';
  if (view === 'browse') return '#/mac/templates/browse';
  if (MAC_SAME.includes(view)) return '#/mac/' + view;
  if (LOG_PAGES.includes(view)) return '#/mac/logs/' + view;
  if (view === 'chat') return '#/chat';
  return HOME;
}
