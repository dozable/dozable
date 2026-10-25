// components/page-title — 647 (owner: "when the page is vertically scrolling, fix the page / panel title as a sticky
// header (in some cases there is also table sticky headers that should appear under it)"). Every page builds its title
// as it always did (a `.head` with its h1 and actions, or an h1 alone); after each render this finds it, marks it
// `.page-title` (sticky, app.css) and keeps two lengths on #view: `--title-h` (the title bar), which a page's own sticky
// tools or index sit under, and `--stack-h` (all that is stuck above the content), which every table's column heads
// sit under.
import { $ } from '../dom/h.js';

let bar = null, tools = null, queued = false;
const sizes = new ResizeObserver(() => measure());

// The h1's ancestor that is a child of the page's root (or the h1 itself): sticky holds only inside its parent, so the
// marked bar must sit directly in the box that holds the whole page.
function titleBar(view) {
  const h1 = view.querySelector('h1');
  if (!h1) return null;
  let el = h1;
  while (el.parentElement && el.parentElement !== view && el.parentElement.parentElement !== view) el = el.parentElement;
  return el;
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
  const b = titleBar(view);
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
