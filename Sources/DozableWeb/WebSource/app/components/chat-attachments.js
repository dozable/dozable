// components/chat-attachments — a message's attachments its text does not show already: a picture (PNG, JPEG, GIF, WebP)
// inline (a click opens the gallery), anything else a chip that downloads. Only this chat server's files, at the dashboard's own address.
import { fileUrl } from '../core/chat-api.js';
import { h } from '../dom/h.js';
import { icon } from '../dom/icons.js';
import { showGallery } from './chat-gallery.js';

const size = (n) => (n >= 1048576 ? (n / 1048576).toFixed(1) + ' MB' : n >= 1024 ? Math.round(n / 1024) + ' KB' : n + ' bytes');

export function drawAtts(m) {
  const box = m._atts;
  if (!box) return;
  const kids = [];
  for (const a of m.attachments || []) {
    const url = String(a.url || ''), src = fileUrl(url);
    if (!src) continue;
    if ((m.content || '').includes(url) || (m.content || '').includes(url.replace(/ /g, '%20'))) continue;
    const name = String(a.name || 'file');
    if (/^image\/(png|jpeg|gif|webp)$/.test(a.type)) {
      const im = h('img', { class: 'chat-att', src, alt: name, title: name + ' · ' + size(+a.size || 0), loading: 'lazy', tabindex: '0', role: 'button' });
      im.addEventListener('click', (e) => { e.stopPropagation(); showGallery(im); });
      im.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); showGallery(im); } });
      kids.push(im);
    }
    else kids.push(h('a', { class: 'chat-fchip', href: src, download: name }, icon('file'), name + ' ', h('small', { class: 'chat-fchip-size' }, size(+a.size || 0))));
  }
  box.replaceChildren(...kids);
}
