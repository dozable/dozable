// core/windows — the only windows this page opens. The browser's own `window.open` is kept here, before
// components/terminal.js (which imports this module, so it runs first) replaces it with a refusal: a terminal's program
// never opens a window by itself. What may open:
//   · Dozable's own two pages, by name, so a second open REUSES the window (a fragment change, never a reload): a room's
//     chat window `/chat#/ROOM`, and a workspace's space editor `/#/w/NAME/space[/watch]`;
//   · a web address a person Cmd-clicked in a terminal (`openExternal` — the terminal checks it with safeLink first).
const nativeOpen = window.open.bind(window);

const OWN = [/^\/chat#\/[a-z0-9][a-z0-9_-]{0,63}$/, /^\/#\/w\/[a-z0-9][a-z0-9-]{0,39}\/space(?:\/watch)?$/];
const NAME = /^doz-(?:chat|space)-[a-z0-9][a-z0-9_-]{0,63}$/;

/// Whether `path` is one of Dozable's own pages that open in a window of their own.
export const isOwnWindowPath = (path) => OWN.some((re) => re.test(String(path || '')));

/// Open (or bring forward) Dozable's own page `path` in the window named `name`, `size` {w, h} — a popup of this origin.
/// Without noopener: noopener stops a named window being reused, and the page is this origin's own. Anything else is
/// refused (null).
export function openOwnWindow(path, name, size = {}) {
  if (!isOwnWindowPath(path) || !NAME.test(String(name || ''))) return null;
  const w = Math.max(320, Math.min(2400, +size.w || 440)), hh = Math.max(320, Math.min(1600, +size.h || 760));
  const win = nativeOpen(path, name, 'popup,width=' + w + ',height=' + hh);
  if (win) { try { win.focus(); } catch (_) { /* the browser decides */ } }
  return win;
}

/// A web address of another computer, in a new tab with no opener and no referrer (the terminal's Cmd-click — checked by
/// its caller with safeLink).
export function openExternal(href) {
  return nativeOpen(href, '_blank', 'noopener,noreferrer');
}
