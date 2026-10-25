// dom/h — h() and $(): the page is built with these — text only (590: never HTML).


// ── tiny DOM helpers (text only) ────────────────────────────────────────────
export function h(tag, attrs, ...kids) {
  const el = document.createElement(tag);
  if (attrs) {
    for (const [k, v] of Object.entries(attrs)) {
      if (v === undefined || v === null || v === false) continue;
      if (k === 'class') el.className = v;
      else if (k === 'on') for (const [ev, fn] of Object.entries(v)) el.addEventListener(ev, fn);
      else el.setAttribute(k, v === true ? '' : String(v));
    }
  }
  for (const kid of kids.flat()) {
    if (kid === undefined || kid === null || kid === false) continue;
    el.append(kid instanceof Node ? kid : document.createTextNode(String(kid)));
  }
  return el;
}
export const $ = (id) => document.getElementById(id);
/// 647: a class on each element child of `el` — for a container whose rule is about its children (a flex column's items),
/// so the stylesheet keys on that class rather than `> *` (a universal key makes every element on the page a candidate).
/// `skip` names a tag left out (a disclosure's SUMMARY).
export function markChildren(el, cls, skip) {
  for (const c of el.children) if (c.tagName !== skip) c.classList.add(cls);
  return el;
}
