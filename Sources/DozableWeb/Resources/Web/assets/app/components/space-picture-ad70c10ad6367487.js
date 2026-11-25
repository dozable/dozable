// components/space-picture — The workspace drawn (core/space-pictures.js): thumbnails and the hero, every workspace — a
// space file's hero links to its editor; a plain one's (from its document) links nowhere. A tile when not readable or drawn.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-aaec6b77d82a3494.js';
import { dropPicture, pictureProblems, pictureView, setPictureSize, setPictureVisible } from '../core/space-pictures-8029e9901879ab72.js';
import { spaceHash } from '../core/routes-0babfc190b1519e4.js';
import { cmdLine } from './cmd-line-adc8d3a1a3dcde29.js';
import { watchVisible } from './grid-feed-55d96839bb2271d4.js';

const THUMB = { w: 160, h: 100 };     // CSS sizes it
const slots = new Map();

export function pictureTile(why, cls) {
  return h('span', { class: 'sp-tile' + (cls ? ' ' + cls : ''), title: why, 'data-pic-tile': why }, icon('boxes'), h('span', { class: 'sr-only' }, why));
}
const why = (text) => h('span', { class: 'ws-hero-why' }, text);
const bigTile = (pic, text) => pic.replaceChildren(pictureTile(text, 'sp-tile-hero'), why(text));

/// A row's thumbnail (home|list|nav), kept per place and name: a redraw moves it.
export function spaceThumb(row, place) {
  const k = place + ':' + row.name, plain = !row.space;
  const have = slots.get(k);
  if (have && have.plain === plain) return have.el;
  if (have) forgetSlot(k);
  const img = h('img', { class: 'sp-img', alt: row.name + (plain ? ', drawn from its record' : ', drawn from its space file'), width: String(THUMB.w), height: String(THUMB.h), decoding: 'async', hidden: true });
  const el = h('span', { class: 'sp-thumb sp-thumb-' + place, 'data-pic': row.name, 'data-pic-place': place }, img);
  const view = pictureView(row.name, 'thumb', THUMB, el, (r) => {
    if (!r.src && !r.fallback) return;
    for (const t of el.querySelectorAll('.sp-tile')) t.remove();
    img.hidden = !r.src;
    el.classList.toggle('is-problem', !!r.problem);
    if (r.src) { img.src = r.src; el.dataset.picKey = r.key; return; }
    delete el.dataset.picKey;
    if (place === 'nav') el.hidden = true; else el.append(pictureTile(r.fallback));
  }, { plain });
  const unwatch = watchVisible(el, (v) => setPictureVisible(view, v));
  slots.set(k, { el, view, unwatch, plain });
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

/// The hero (Home only): o {name, file, edit, plain} — plain (fixed): no link, `doz workspace doc NAME` beside it.
/// → {el, set(o), dispose()}.
export function spaceHero(o) {
  let cur = o, view = null, unwatch = null, problemFor = null;
  const plain = !!o.plain;
  const pic = h('div', { class: 'ws-hero-pic', 'aria-hidden': 'true' });
  const hero = plain ? h('div', { class: 'ws-hero is-plain', role: 'img', 'data-ws-hero': o.name, 'data-ws-hero-plain': '' }, pic)
    : h('a', { class: 'ws-hero', href: spaceHash(o.name), 'data-ws-hero': o.name }, pic);
  const open = plain ? h('span', { class: 'ws-hero-doc', 'data-ws-hero-doc': '' }) : h('a', { class: 'btn sm ws-hero-open', href: spaceHash(o.name), 'data-ws-hero-open': '' });
  const problem = h('div', { class: 'ws-hero-problem', 'data-ws-hero-problem': '', hidden: true });
  const label = h('span', { class: 'ws-hero-label' });
  const el = h('section', { class: 'ws-hero-band', 'aria-label': 'The picture', 'data-ws-hero-band': o.name },
    h('div', { class: 'ws-hero-head' }, label, open), hero, problem);
  function paint(r) {
    if (r.reading) { if (!pic.childElementCount) pic.replaceChildren(why('drawing…')); return; }
    if (r.svg) { pic.replaceChildren(r.svg); hero.dataset.picKey = r.key; } else { bigTile(pic, r.fallback); delete hero.dataset.picKey; }
    hero.classList.toggle('is-fallback', !r.svg);
    showProblem(!!r.problem);
  }
  async function showProblem(on) {
    if (!on) { problem.hidden = true; problemFor = null; return; }
    const p = plain ? { sha: 1, list: [] } : await pictureProblems(cur.name);
    if (!p || problemFor === p.sha) return;
    problemFor = p.sha;
    const more = p.count > p.list.length ? ' (+' + (p.count - p.list.length) + ' more)' : '';
    problem.replaceChildren(h('p', { class: 'ws-hero-problem-text' }, icon('triangle-alert'), plain ? 'Its document doesn’t draw here: ' : 'This file doesn’t read: ',
      plain ? '' : p.list.length ? p.list.join(' · ') + more : p.error || 'Dozable found no problem the drawing names'),
    cmdLine(plain ? doc() : 'doz workspace up -f ' + (p.shownPath || cur.file) + ' --dry-run'));
    problem.hidden = false;
  }
  const shown = (v) => { document.body.classList.toggle('ws-hero-on', v); setPictureVisible(view, v); };
  const doc = () => 'doz workspace doc ' + cur.name;
  function draw() {
    if (plain) {
      label.replaceChildren(icon('boxes'), h('span', null, 'Drawn from its record — made without a space file'));
      hero.setAttribute('aria-label', cur.name + ', drawn from its record');
      open.replaceChildren(cmdLine(doc()));
    } else draw2();
    if (!view) {
      view = pictureView(cur.name, 'hero', heroSize(), hero, paint, { plain });
      unwatch = watchVisible(hero, shown);
    }
  }
  function draw2() {
    label.replaceChildren(icon('boxes'), h('span', null, 'Drawn from ', h('code', null, cur.file)));
    const verb = cur.edit ? 'Edit the space' : 'Open the space';
    hero.href = open.href = spaceHash(cur.name);
    hero.setAttribute('aria-label', cur.name + ', drawn from its space file ' + cur.file + ' — ' + verb.toLowerCase());
    open.replaceChildren(icon(cur.edit ? 'pencil' : 'eye'), verb);
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
