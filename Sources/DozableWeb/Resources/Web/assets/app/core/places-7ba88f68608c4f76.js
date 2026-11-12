// core/places — where a session lives: a sandbox, or THIS Mac (`@mac`, `doz run @mac` — no isolation). Each has its own
// typed routes; a session on this Mac is never addressed as a sandbox. One helper for every route that names a session's
// place: a terminal's ticket and socket, a saved screen.
export const MAC = '@mac';

/// Whether `place` is this Mac.
export function isMac(place) { return place === MAC; }

/// The API path of a place (`api(...)` adds /api/v1/): `mac`, or `sandboxes/NAME`.
export function placePath(place) {
  return isMac(place) ? 'mac' : 'sandboxes/' + encodeURIComponent(place);
}

/// A session's saved screen.
export function screenPath(place, session) {
  return placePath(place) + '/sessions/' + encodeURIComponent(session) + '/screen';
}
