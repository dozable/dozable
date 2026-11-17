// components/chat-attachments — a message's attachments its text does not show already: a picture (PNG, JPEG, GIF, WebP)
// inline, anything else a chip that downloads. Only this chat server's files, at the dashboard's own address.
import { fileUrl } from '../core/chat-api-1d17d676033725e8.js';
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';

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
    if (/^image\/(png|jpeg|gif|webp)$/.test(a.type)) kids.push(h('img', { class: 'chat-att', src, alt: name, title: name + ' · ' + size(+a.size || 0), loading: 'lazy' }));
    else kids.push(h('a', { class: 'chat-fchip', href: src, download: name }, icon('file'), name + ' ', h('small', { class: 'chat-fchip-size' }, size(+a.size || 0))));
  }
  box.replaceChildren(...kids);
}
