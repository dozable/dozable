// components/page-title — 647 (owner: "when the page is vertically scrolling, fix the page / panel title as a sticky
// header (in some cases there is also table sticky headers that should appear under it)"). Every page builds its title
// as it always did (a `.head` with its h1 and actions, or an h1 alone); after each render this finds it, marks it
// `.page-title` (sticky, app.css) and keeps two lengths on #view: `--title-h` (the title bar), which a page's own sticky
// tools or index sit under, and `--stack-h` (all that is stuck above the content), which every table's column heads
// sit under.
import { $ } from '../dom/h-f853cc7eb6672c45.js';

let bar = null, tools = null, queued = false;
const sizes = new ResizeObserver(() => measure());

// The bar is the h1's `.head` (else the h1). Sticky holds only inside its parent's box, so the bar must sit directly
// in the box that holds the whole page: a plain wrapper between them (no class — the overview's title, line and figures)
// is given no box of its own (`.title-wrap`, display: contents); a wrapper with a class of its own is styled, so then
// that wrapper is the bar.
let wraps = [];
function titleBar(view) {
  const h1 = view.querySelector('h1');
  if (!h1) return null;
  const head = h1.parentElement && h1.parentElement.classList.contains('head') ? h1.parentElement : h1;
  const plain = [];
  let el = head;
  while (el.parentElement && el.parentElement !== view && el.parentElement.parentElement !== view) {
    const up = el.parentElement;
    if (up.className && !up.classList.contains('title-wrap')) {                   // a styled wrapper: it is the bar
      let top = up;
      while (top.parentElement && top.parentElement !== view && top.parentElement.parentElement !== view) top = top.parentElement;
      return { bar: top, plain: [] };
    }
    plain.push(up);
    el = up;
  }
  return { bar: head, plain };
}
function measure() {
  const view = $('view');
  if (!view) return;
  const t = bar && bar.isConnected ? bar.offsetHeight : 0;
  const k = tools && tools.isConnected ? tools.offsetHeight : 0;
  view.style.setProperty('--title-h', t + 'px');
  view.style.setProperty('--stack-h', 'calc(var(--header-h) + ' + (t + k) + 'px)');
}
function mark() {
  const view = $('view');
  if (!view) return;
  const found = titleBar(view);
  const b = found ? found.bar : null;
  for (const w of wraps) if (!found || !found.plain.includes(w)) w.classList.remove('title-wrap');
  wraps = found ? found.plain : [];
  for (const w of wraps) w.classList.add('title-wrap');
  if (b !== bar) {
    if (bar) { sizes.unobserve(bar); bar.classList.remove('page-title', 'is-stuck'); }
    bar = b;
    if (bar) { bar.classList.add('page-title'); sizes.observe(bar); }
  }
  stuck();
  const k = view.querySelector('.page-tools, .page-index');
  if (k !== tools) {
    if (tools) sizes.unobserve(tools);
    tools = k;
    if (tools) sizes.observe(tools);
  }
  measure();
}
// A line under the bar only once the page has scrolled under it.
function stuck() { if (bar) bar.classList.toggle('is-stuck', window.scrollY > 0); }
/// Called once by app.js: every change inside #view (a route, a repaint) marks the title again on the next microtask.
export function watchPageTitle() {
  const view = $('view');
  if (!view) return;
  window.addEventListener('scroll', stuck, { passive: true });
  new MutationObserver(() => {
    if (queued) return;
    queued = true;
    queueMicrotask(() => { queued = false; mark(); });
  }).observe(view, { childList: true, subtree: true });
  mark();
}
