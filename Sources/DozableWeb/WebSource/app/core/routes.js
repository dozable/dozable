// core/routes — The page's addresses: what a hash names (`parse`), and the old addresses that lead to today's (`canonical`,
// `LEGACY`). Pure: no DOM, no state. The router replaces an old address with its canonical one first, then parses.
//
// Today's addresses: #/home · #/chat[/ROOM] · #/workspaces (every workspace, rows or a grid) · #/w/NAME (a workspace's
// page: its Home tab) · #/w/NAME/room[/LABEL] (its Room tab: its main room, or another of its rooms by its short label) ·
// #/w/NAME/agents (its Agents tab) · #/w/NAME/network, /folders, /activity (its Network &
// secrets, Folders & points and Activity tabs) · #/w/NAME/agent/AGENT[/SESSION|~home] (an agent's screen: its sandbox's or
// its session's page, framed by the workspace) · #/w/NAME/agent/AGENT/can-do (what it can do) · #/bots · #/bots/~new (a new Agent / Bot) · #/bots/NAME[/TAB]
// (one Agent / Bot: across its workspaces, or an edit tab — BOT_TABS) · #/sandbox/NAME[/SESSION|~home] · #/mac (This Mac) and its pages,
// #/mac/here[/SESSION] (the sessions on this Mac), #/mac/sessions, #/mac/sandboxes, #/mac/loose, #/mac/macs (Your Macs), #/mac/templates[/browse |
// /V/P], #/mac/images, accounts, resources, devices, doctor, settings, debug, #/mac/logs/<operations|activity|notifications|
// metrics> · the modals #/new (New sandbox), #/new-workspace[?bot=NAME] (New workspace, its manager chosen), #/onboarding,
// #/try[/AGENT] · #/guide/isolation[/vm|fenced|unfenced|elsewhere] (where an agent runs: the four choices, one highlighted) ·
// #/w/NAME/agents/new (Add a worker — a page of its own, this Mac's own browser's).

/// The words after #/mac/ that name a page of This Mac (a session on this Mac named like one loses its old deep link).
export const MAC_RESERVED = ['here', 'sessions', 'sandboxes', 'loose', 'templates', 'images', 'accounts', 'resources', 'devices', 'logs',
  'doctor', 'settings', 'debug', 'macs'];
/// This Mac's pages whose view keeps its old name (#/mac/images → view `images`).
const MAC_SAME = ['images', 'accounts', 'resources', 'devices', 'doctor', 'settings', 'debug'];
/// This Mac › Logs.
export const LOG_PAGES = ['operations', 'activity', 'notifications', 'metrics'];
/// The modals over the page.
export const MODAL_VIEWS = new Set(['new', 'new-workspace', 'onboarding', 'try']);
/// The page an empty or unknown address opens.
export const HOME = '#/home';

const RECIPE = '[a-z0-9-]{1,40}(?:/[a-z0-9-]{1,40}){1,2}';
/// A workspace's name (the store's rule) and a room's short label (the chat server's room rule).
const WORKSPACE = '[a-z0-9][a-z0-9-]{0,39}';
const ROOM_LABEL = '[a-z0-9][a-z0-9_-]{0,63}';
const MAC_SESSION = '[A-Za-z0-9_-][A-Za-z0-9._-]{0,31}';
/// An agent's name in a workspace (the store's rule: 1–64 of letters, digits . _ -, not starting with - or .).
const AGENT = '[A-Za-z0-9_][A-Za-z0-9._-]{0,63}';
const SESSION = '[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}';
/// An Agent / Bot's name (the chat rule: a lower-case letter, then lower-case letters, digits and -, at most 40) — so `~new` never
/// clashes with one.
const BOT = '[a-z][a-z0-9-]{0,39}';
/// A bot screen's tabs after "Across workspaces" (its own address, #/bots/NAME): the edit tabs, then Roles & ceiling.
export const BOT_TABS = ['identity', 'runs', 'reached', 'instructions', 'account', 'roles'];
/// A workspace's tabs drawn from a read of their own (Home is #/w/NAME itself, the Room tab #/w/NAME/room[/LABEL]).
export const WS_VIEW_TABS = ['agents', 'network', 'folders', 'activity', 'runs'];
/// The isolation guide's choices, in order of isolation (core/isolation.js has their words).
export const GUIDE_ISOLATIONS = ['vm', 'fenced', 'unfenced', 'elsewhere'];

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
  // A workspace's Home has one address: #/w/NAME (a trailing slash, or /home, lead to it); /room/ to its Room tab.
  [new RegExp('^#/w/(' + WORKSPACE + ')/(?:home)?$'), (m) => '#/w/' + m[1]],
  [new RegExp('^#/w/(' + WORKSPACE + ')/room/$'), (m) => '#/w/' + m[1] + '/room'],
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

/// What a canonical address names: {view, param, session, recipe, room, tab, agent, modal} (null: not an address of the
/// page). `view` is the page's view name (`state.view`); `recipe` is '' for the templates' list, 'V/P' for one, null
/// otherwise; `room` a workspace room's short label (#/w/NAME/room/LABEL; null: its main room); `tab` a workspace's tab
/// (`home` — #/w/NAME —, `room`, `agents`, …); `agent` an agent's name in the workspace (view `wsagent`: the router opens its
/// sandbox's or its session's page, framed).
export function parse(hash) {
  const r = (view, o = {}) => ({ view, param: o.param || null, session: o.session || null, recipe: o.recipe === undefined ? null : o.recipe,
    room: o.room || null, tab: o.tab || null, agent: o.agent || null, modal: !!o.modal });
  let m;
  if (hash === '#/home') return r('home');
  if (hash === '#/bots') return r('bots');
  if (hash === '#/workspaces') return r('workspaces');
  if (hash === '#/bots/~new') return r('bot', { param: '~new' });
  if ((m = new RegExp('^#/bots/(' + BOT + ')(?:/(' + BOT_TABS.join('|') + '))?$').exec(hash))) return r('bot', { param: m[1], tab: m[2] });
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
  if ((m = new RegExp('^#/w/(' + WORKSPACE + ')$').exec(hash))) return r('workspace', { param: m[1], tab: 'home' });
  if ((m = new RegExp('^#/w/(' + WORKSPACE + ')/room(?:/(' + ROOM_LABEL + '))?$').exec(hash))) return r('workspace', { param: m[1], tab: 'room', room: m[2] });
  if ((m = new RegExp('^#/w/(' + WORKSPACE + ')/(' + WS_VIEW_TABS.join('|') + ')$').exec(hash))) return r('workspace', { param: m[1], tab: m[2] });
  if ((m = new RegExp('^#/w/(' + WORKSPACE + ')/agents/new$').exec(hash))) return r('addworker', { param: m[1] });
  if ((m = new RegExp('^#/guide/isolation(?:/(' + GUIDE_ISOLATIONS.join('|') + '))?$').exec(hash))) return r('guide', { param: m[1] });
  if ((m = new RegExp('^#/w/(' + WORKSPACE + ')/agent/(' + AGENT + ')/can-do$').exec(hash))) return r('wsagent', { param: m[1], agent: m[2], tab: 'can-do' });
  if ((m = new RegExp('^#/w/(' + WORKSPACE + ')/agent/(' + AGENT + ')(?:/(~home|' + SESSION + '))?$').exec(hash)) && m[3] !== 'can-do') {
    return r('wsagent', { param: m[1], agent: m[2], session: m[3] });
  }
  // 635: `~home` (no session name can hold a ~) selects a sandbox page's Home tab.
  if ((m = /^#\/sandbox\/([a-z0-9-]{1,40})(?:\/(~home|[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}))?$/.exec(hash))) return r('sandbox', { param: m[1], session: m[2] });
  if (hash === '#/new' || hash === '#/onboarding') return r(hash.slice(2), { modal: true });
  if ((m = new RegExp('^#/new-workspace(?:\\?bot=(' + BOT + '))?$').exec(hash))) return r('new-workspace', { param: m[1], modal: true });
  if ((m = /^#\/try(?:\/([a-z0-9-]{1,40}))?$/.exec(hash))) return r('try', { param: m[1], modal: true });
  return null;
}

/// A workspace's Room tab: its main room (`label` null), or another of its rooms by its short label.
export function roomHash(name, label) { return '#/w/' + name + '/room' + (label ? '/' + label : ''); }
/// A workspace's page — its Home tab; with a `label`, that room (`roomHash`).
export function workspaceHash(name, label) { return label ? roomHash(name, label) : '#/w/' + name; }
/// An Agent / Bot's screen (`tab`: one of BOT_TABS; none: Across workspaces), or `~new` for a new one.
export function botHash(name, tab) { return '#/bots/' + name + (tab ? '/' + tab : ''); }
/// The isolation guide, at one choice (`id`: vm, fenced, unfenced, elsewhere; none: the top).
export function guideHash(id) { return '#/guide/isolation' + (id ? '/' + id : ''); }
/// A workspace's Add a worker page.
export function addWorkerHash(name) { return '#/w/' + name + '/agents/new'; }
/// A workspace's Agents tab.
export function agentsHash(name) { return '#/w/' + name + '/agents'; }
/// A workspace's Network & secrets, Folders & points and Activity tabs.
export function networkHash(name) { return '#/w/' + name + '/network'; }
export function foldersHash(name) { return '#/w/' + name + '/folders'; }
export function activityHash(name) { return '#/w/' + name + '/activity'; }
/// A workspace's Runs tab: its runs, their archives, its rooms.
export function runsHash(name) { return '#/w/' + name + '/runs'; }
/// What an agent of a workspace can do.
export function canDoHash(workspace, agent) { return '#/w/' + workspace + '/agent/' + encodeURIComponent(agent) + '/can-do'; }
/// An agent's screen in its workspace (`session`: a session of its sandbox, or `~home`).
export function agentHash(workspace, agent, session) {
  return '#/w/' + workspace + '/agent/' + encodeURIComponent(agent) + (session ? '/' + session : '');
}

/// THE address of a place's page — every writer of `#/sandbox/…` or `#/mac/here/…` goes through it: `kind` 'sandbox'
/// (`name` the sandbox, `session` one of its sessions or `~home`) or 'mac' (`name` the session on this Mac). While the
/// page is framed by a workspace (`frame` — `state.frame`: {workspace, agent, kind, place}) and the place is the frame's,
/// the address stays the framed one (#/w/NAME/agent/AGENT[/SESSION]); anything else is the place's own address.
export function placeHash(kind, name, session, frame) {
  if (frame && frame.kind === kind && frame.place === name) {
    return agentHash(frame.workspace, frame.agent, kind === 'sandbox' ? session : null);
  }
  if (kind === 'mac') return '#/mac/here' + (name ? '/' + encodeURIComponent(name) : '');
  return '#/sandbox/' + name + (session ? '/' + session : '');
}

/// The address of a view with no parameter (the sidebar's and a link's): `hashFor('images')` → '#/mac/images'.
export function hashFor(view) {
  if (view === 'home' || view === 'bots' || view === 'workspaces') return '#/' + view;
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
