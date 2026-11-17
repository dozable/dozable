// components/chat-gallery — the room's pictures, one at a time over the page: the arrows (or ← →) step through them, a
// strip of thumbnails, Save, and Escape or a click outside closes. Only the pictures the log shows (this chat server's PNG,
// JPEG, GIF and WebP at the dashboard's own address); every caption is text.
import { cap } from '../core/chat-format-bc877d395788e64c.js';
import { $, h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';

export function showGallery(from) {
  const pics = [...$('chat-log').querySelectorAll('img.chat-att')];
  if (!pics.length) return;
  let i = Math.max(0, pics.indexOf(from));
  const pic = h('img', { class: 'chat-galpic', alt: '', draggable: 'false' });
  const caption = h('div', { class: 'chat-galcap' });
  const btn = (name, label) => h('button', { type: 'button', class: 'chat-galbtn', title: label, 'aria-label': label }, icon(name));
  const prev = btn('chevron-left', 'Previous picture'), next = btn('chevron-right', 'Next picture'), close = btn('x', 'Close');
  const save = h('a', { class: 'chat-galbtn', title: 'Save this picture', 'aria-label': 'Save this picture' }, icon('download'));
  const strip = h('div', { class: 'chat-galstrip' });
  const foot = h('div', { class: 'chat-galfoot' }, prev, strip, next);
  const back = h('div', { class: 'chat-gal', role: 'dialog', 'aria-modal': 'true', 'aria-label': 'Pictures in this room' },
    h('div', { class: 'chat-galbar' }, caption, save, close), pic, foot);
  const who = (im) => { const r = im.closest('.chat-row'); return r && r.dataset.who ? cap(r.dataset.who) : ''; };
  const show = () => {
    const im = pics[i];
    pic.src = im.getAttribute('src');       // the dashboard's own relative address, as the log has it
    pic.alt = im.alt || '';
    save.href = im.getAttribute('src');
    save.setAttribute('download', im.alt || '');
    caption.textContent = [who(im), im.alt, (i + 1) + ' of ' + pics.length].filter(Boolean).join(' · ');
    foot.hidden = pics.length < 2;
    [...strip.children].forEach((t, k) => { t.classList.toggle('is-on', k === i); t.setAttribute('aria-current', k === i ? 'true' : 'false'); });
    const on = strip.children[i];
    if (on) on.scrollIntoView({ block: 'nearest', inline: 'center' });
  };
  const go = (d) => { i = (i + d + pics.length) % pics.length; show(); };
  const key = (e) => {
    if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); shut(); }
    else if (e.key === 'ArrowLeft') { e.preventDefault(); go(-1); }
    else if (e.key === 'ArrowRight') { e.preventDefault(); go(1); }
  };
  function shut() { document.removeEventListener('keydown', key, true); back.remove(); if (from.isConnected) from.focus(); }
  pics.forEach((im, k) => {
    const t = h('button', { type: 'button', class: 'chat-galthumb', title: im.alt || 'Picture ' + (k + 1), 'aria-label': 'Picture ' + (k + 1) + ' of ' + pics.length },
      h('img', { class: 'chat-galthumb-img', src: im.getAttribute('src'), alt: '', loading: 'lazy' }));
    t.addEventListener('click', (e) => { e.stopPropagation(); i = k; show(); });
    strip.append(t);
  });
  prev.addEventListener('click', (e) => { e.stopPropagation(); go(-1); });
  next.addEventListener('click', (e) => { e.stopPropagation(); go(1); });
  close.addEventListener('click', (e) => { e.stopPropagation(); shut(); });
  for (const x of [save, pic, foot]) x.addEventListener('click', (e) => e.stopPropagation());
  back.addEventListener('click', shut);
  document.body.append(back);
  document.addEventListener('keydown', key, true);
  show();
  close.focus();
}
