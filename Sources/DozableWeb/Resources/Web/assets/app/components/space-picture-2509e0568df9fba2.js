// components/space-picture — The workspace drawn (core/space-pictures.js draws it): thumbnails, the hero, the full
// view; a plain tile with no file, one not readable here or not drawn. A hero on screen moves the toasts (ws-hero-on).
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { dropPicture, pictureProblems, pictureView, setPictureSize, setPictureVisible } from '../core/space-pictures-622217d6b216e9a5.js';
import { cmdLine } from './cmd-line-d408fcba356d6a76.js';
import { watchVisible } from './grid-feed-9b440bce8b7e5e9a.js';

const THUMB = { w: 160, h: 100 };     // Home's and the sidebar's (CSS sizes it)
const slots = new Map();

export function pictureTile(why, cls) {
  return h('span', { class: 'sp-tile' + (cls ? ' ' + cls : ''), title: why, 'data-pic-tile': why }, icon('boxes'), h('span', { class: 'sr-only' }, why));
}
const why = (text) => h('span', { class: 'ws-hero-why' }, text);
const bigTile = (pic, text) => pic.replaceChildren(pictureTile(text, 'sp-tile-hero'), why(text));

/// A row's thumbnail (home|nav), kept per place and name: a redraw moves it.
export function spaceThumb(row, place) {
  const k = place + ':' + row.name;
  if (!row.space) { forgetSlot(k); return place === 'nav' ? null : h('span', { class: 'sp-thumb sp-thumb-' + place }, pictureTile('Made without a space file')); }
  const have = slots.get(k);
  if (have) return have.el;
  const img = h('img', { class: 'sp-img', alt: row.name + ', drawn from its space file', width: String(THUMB.w), height: String(THUMB.h), decoding: 'async', hidden: true });
  const el = h('span', { class: 'sp-thumb sp-thumb-' + place, 'data-pic': row.name, 'data-pic-place': place }, img);
  const view = pictureView(row.name, 'thumb', THUMB, el, (r) => {
    if (!r.src && !r.fallback) return;
    for (const t of el.querySelectorAll('.sp-tile')) t.remove();
    img.hidden = !r.src;
    el.classList.toggle('is-problem', !!r.problem);
    if (r.src) { img.src = r.src; el.dataset.picKey = r.key; return; }
    delete el.dataset.picKey;
    if (place === 'nav') el.hidden = true; else el.append(pictureTile(r.fallback));
  });
  const unwatch = watchVisible(el, (v) => setPictureVisible(view, v));
  slots.set(k, { el, view, unwatch });
  return el;
}
function forgetSlot(k) {
  const s = slots.get(k);
  if (s) { s.unwatch(); dropPicture(s.view); slots.delete(k); }
}
export function forgetThumbs(names, place) {
  for (const k of [...slots.keys()]) if (k.startsWith(place + ':') && !names.includes(k.slice(place.length + 1))) forgetSlot(k);
}

// ── the hero
const narrow = matchMedia('(max-width: 760px)');
const heroSize = () => (narrow.matches ? { w: 800, h: 560 } : { w: 1200, h: 500 });

/// The hero: o {name, file, folded, onFold}; a button that opens the full-window view. → {el, set(o), dispose()}.
export function spaceHero(o) {
  let cur = o, view = null, unwatch = null, problemFor = null;
  const pic = h('div', { class: 'ws-hero-pic', 'aria-hidden': 'true' });
  const hero = h('button', { type: 'button', class: 'ws-hero', 'data-ws-hero': o.name, on: { click: () => openFull(cur.name, hero) } }, pic);
  const problem = h('div', { class: 'ws-hero-problem', 'data-ws-hero-problem': '', hidden: true });
  const fold = h('button', { type: 'button', class: 'btn sm quiet ws-hero-fold', on: { click: () => { cur.folded = !cur.folded; cur.onFold(cur.folded); draw(); } } });
  const label = h('span', { class: 'ws-hero-label' });
  const el = h('section', { class: 'ws-hero-band', 'aria-label': 'The picture', 'data-ws-hero-band': o.name },
    h('div', { class: 'ws-hero-head' }, label, h('span', { class: 'ws-sp' }), fold), hero, problem);
  function paint(r) {
    if (r.reading) { if (!pic.childElementCount) pic.replaceChildren(why('drawing…')); return; }
    if (r.svg) { pic.replaceChildren(r.svg); hero.dataset.picKey = r.key; } else { bigTile(pic, r.fallback); delete hero.dataset.picKey; }
    hero.classList.toggle('is-fallback', !r.svg);
    showProblem(!!r.problem);
  }
  async function showProblem(on) {
    if (!on) { problem.hidden = true; problemFor = null; return; }
    const p = await pictureProblems(cur.name);
    if (!p || problemFor === p.sha) return;
    problemFor = p.sha;
    const more = p.count > p.list.length ? ' (+' + (p.count - p.list.length) + ' more)' : '';
    problem.replaceChildren(h('p', { class: 'ws-hero-problem-text' }, icon('triangle-alert'), 'This file doesn’t read: ',
      p.list.length ? p.list.join(' · ') + more : p.error || 'Dozable found no problem the drawing names'),
    cmdLine('doz workspace up -f ' + (p.shownPath || cur.file) + ' --dry-run'));
    problem.hidden = false;
  }
  const shown = (v) => { document.body.classList.toggle('ws-hero-on', v); setPictureVisible(view, v); };
  function draw() {
    label.replaceChildren(icon('boxes'), h('span', null, 'Drawn from ', h('code', null, cur.file)));
    fold.setAttribute('aria-expanded', cur.folded ? 'false' : 'true');
    fold.replaceChildren(icon(cur.folded ? 'chevron-right' : 'chevron-down'), cur.folded ? 'Show' : 'Fold');
    hero.hidden = !!cur.folded;
    el.classList.toggle('is-folded', !!cur.folded);
    hero.setAttribute('aria-label', cur.name + ', drawn from its space file ' + cur.file + ' — open it in the full window');
    if (cur.folded) { problem.hidden = true; if (view) shown(false); return; }
    if (!view) {
      view = pictureView(cur.name, 'hero', heroSize(), hero, paint);
      unwatch = watchVisible(hero, (v) => shown(v && !cur.folded));
    }
  }
  const onNarrow = () => { if (view) setPictureSize(view, heroSize()); };
  narrow.addEventListener('change', onNarrow);
  draw();
  return {
    el,
    set(n) { const changed = n.name !== cur.name; cur = { ...cur, ...n }; if (changed) { this.drop(); } draw(); },
    drop() { if (unwatch) unwatch(); if (view) { shown(false); dropPicture(view); } view = null; unwatch = null; pic.replaceChildren(); problemFor = null; problem.hidden = true; },
    dispose() { this.drop(); narrow.removeEventListener('change', onNarrow); },
  };
}

export function heroNone(name) {
  return h('section', { class: 'ws-hero-band ws-hero-none', 'aria-label': 'The picture', 'data-ws-hero-none': name },
    pictureTile('Made without a space file'), why('Made without a space file — '), cmdLine('doz workspace up -f FILE'), why(' draws it'));
}

// ── the full-window view (no address of its own)
function openFull(name, from) {
  if (document.querySelector('.sp-full')) return;
  const pic = h('div', { class: 'sp-full-pic' }, why('drawing…'));
  const close = h('button', { type: 'button', class: 'btn sm', 'data-sp-full-close': '' }, icon('x'), 'Close');
  const box = h('div', { class: 'sp-full-box', role: 'dialog', 'aria-modal': 'true', 'aria-label': name + ', drawn from its space file' },
    h('div', { class: 'sp-full-head' }, h('b', null, name), h('span', { class: 'ws-sp' }), close), pic);
  const back = h('div', { class: 'sp-full', 'data-sp-full': name }, box);
  const size = { w: Math.max(320, Math.round(innerWidth - 64)), h: Math.max(240, Math.round(innerHeight - 120)) };
  const view = pictureView(name, 'full', size, pic, (r) => {
    if (r.svg) { pic.replaceChildren(r.svg); pic.dataset.picKey = r.key; } else if (r.fallback) bigTile(pic, r.fallback);
  });
  const shut = () => { dropPicture(view); document.removeEventListener('keydown', onKey, true); back.remove(); if (from.isConnected) from.focus(); };
  const onKey = (ev) => { if (ev.key === 'Escape') { ev.preventDefault(); ev.stopPropagation(); shut(); } };
  close.addEventListener('click', shut);
  back.addEventListener('click', (ev) => { if (ev.target === back) shut(); });
  document.addEventListener('keydown', onKey, true);
  document.body.append(back);
  setPictureVisible(view, true);
  close.focus();
}
