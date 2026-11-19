// core/chat-markdown — a chat message's Markdown, a safe subset, as DOM nodes built with h(). A message is UNTRUSTED (an
// agent wrote it): its text is set as text, no HTML is ever parsed from it, and nothing it says becomes an attribute except
// a link's address (http or https only, through safeLink: no login, never this Mac) and an attachment of this chat server
// (mapped to the dashboard's own address). The subset is in docs/engineering/web.md ("Chat"); the corpus is
// Tests/Fixtures/chat-markdown-cases.json, checked in a real browser by Scripts/chat-markdown-check.mjs.
//
// Block level: paragraphs (lines joined with <br>), # to #### headings, - * + and 1. 1) lists, > quotes, ``` fences, pipe tables.
// Inline: `code`, ![alt](/files/<id>/<name>) pictures, [text](/files/...) and [text](http(s)://...) links, bare http(s)
// addresses, **bold**, *italic*, _italic_ and @members. Nothing else is special.
import { state } from './state-3b49d54e8d9b6a73.js';
import { fileUrl } from './chat-api-ec968582d97ebdcb.js';
import { safeLink } from './util-0745432f65992dcb.js';
import { h } from '../dom/h-f853cc7eb6672c45.js';

// The inline passes work on one string, in order. Where a pass makes an element it leaves one private-use character in
// the string and keeps the element's description beside it, so later passes still see the text around it (bold may hold
// a link, a link's text may hold italics) but never reach inside an element's attributes. At the end the string is walked
// once and turned into nodes.
const escH = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const unesc = (s) => s.replace(/&(amp|lt|gt|quot);?/g, (m, n) => ({ amp: '&', lt: '<', gt: '>', quot: '"' })[n]);
const CODE_FIRST = 0xE000, TAG_FIRST = 0xF000, LAST = 0xF8FF;   // code markers E000..EFFF, tag markers F000..F8FF
const FILE = '\\/files\\/(?:[0-9a-f]{16}|[0-9a-f]{32})\\/[^\\s)\\uE000-\\uF8FF]+';
const PICTURE = new RegExp('!\\[([^\\]\\n\\uF000-\\uF8FF]*)\\]\\((' + FILE + ')\\)', 'g');
const FILE_LINK = new RegExp('\\[([^\\]\\n]+)\\]\\((' + FILE + ')\\)', 'g');

function inline(raw) {
  let s = escH(raw.replace(/\u0000/g, ''));
  const taken = new Set(s.match(/[-]/g) || []);   // a marker is never a character the text already has
  const specs = new Map();
  let nextCode = CODE_FIRST, nextTag = TAG_FIRST;
  const alloc = (spec, isCode) => {
    for (;;) {
      const n = isCode ? nextCode++ : nextTag++;
      if (n > (isCode ? TAG_FIRST - 1 : LAST)) return null;
      const ch = String.fromCharCode(n);
      if (!taken.has(ch)) { specs.set(ch, spec); return ch; }
    }
  };
  const closers = {};
  const close = (tag) => closers[tag] || (closers[tag] = alloc({ close: tag }, false));
  const opens = {};   // one marker serves every opener that is the same, so a long message never runs out
  const open = (tag, attrs) => { const k = tag + JSON.stringify(attrs); return opens[k] || (opens[k] = alloc({ open: tag, attrs }, false)); };
  const wrap = (tag, attrs, inner) => { const o = open(tag, attrs), c = close(tag); return o && c ? o + inner + c : inner; };
  // A link opens in a new tab with no opener and no referrer. `u` is the address as written (escaped); it is a link only
  // when the gate admits it, else the text stays as typed.
  const A = (u, t) => wrap('a', { href: u, target: '_blank', rel: 'noopener noreferrer', referrerpolicy: 'no-referrer' }, t);
  const web = (u) => (safeLink(unesc(u)) ? u : null);
  const ours = (u) => { const f = fileUrl(unesc(u)); return f ? escH(f) : null; };

  s = s.replace(/`([^`\n]+)`/g, (m, c) => alloc({ code: c }, true) || m);
  // a picture's alt text is text: a code span inside it is written back as it was typed
  const asText = (t) => t.replace(/[-]/g, (ch) => (specs.has(ch) ? '`' + specs.get(ch).code + '`' : ch));
  s = s.replace(PICTURE, (m, t, u) => { const f = ours(u); return (f && alloc({ img: { class: 'chat-att', src: f, alt: asText(t), loading: 'lazy' } }, false)) || m; });
  s = s.replace(FILE_LINK, (m, t, u) => { const f = ours(u); return f ? A(f, t) : m; });
  s = s.replace(/\[([^\]\n]+)\]\((https?:\/\/[^\s)-]+)\)/g, (m, t, u) => (web(u) ? A(u, t) : m));
  s = s.replace(/(^|[\s(])(https?:\/\/[^\s<)-]*[^\s<).,;:!?-])/g, (m, p, u) => (web(u) ? p + A(u, u) : m));
  s = s.replace(/\*\*([^*\n]+)\*\*/g, (m, x) => wrap('strong', {}, x))
       .replace(/(^|[^\w*])\*([^*\s][^*\n]*)\*(?!\w)/g, (m, p, x) => p + wrap('em', {}, x))
       .replace(/(^|[^\w_])_([^_\s][^_\n]*)_(?!\w)/g, (m, p, x) => p + wrap('em', {}, x));
  // a mention is not made right after a tag, a word, an @, a slash, a dot or an equals sign
  s = s.replace(/(^|[^\w@/.=-])@([A-Za-z0-9][A-Za-z0-9_-]*)/g, (m, p, n) => {
    if (!state.chat.members.has(n.toLowerCase())) return m;
    return p + wrap('span', { class: 'chat-mention' }, '@' + n);
  });
  return build(s, specs);
}

// The string with its markers, as nodes. A tag that closes while others opened inside it are still open closes them too;
// strong and em are reopened after it (as an HTML parser would); a link inside a link ends the first.
function build(s, specs) {
  const stack = [{ el: null }];
  const out = [];
  const put = (node) => { const t = stack[stack.length - 1]; if (t.el) t.el.append(node); else out.push(node); };
  let buf = '';
  const flush = () => { if (buf) { put(document.createTextNode(unesc(buf))); buf = ''; } };
  const start = (tag, attrs) => {
    const el = h(tag, attrs && Object.keys(attrs).length ? decode(attrs) : null);
    put(el);
    stack.push({ el, tag, attrs });
  };
  for (const ch of s) {
    const sp = specs.get(ch);
    if (!sp) { buf += ch; continue; }
    flush();
    if (sp.code !== undefined) put(h('code', null, unesc(sp.code) || null));
    else if (sp.img) put(h('img', decode(sp.img)));
    else if (sp.open) {
      if (sp.open === 'a') { const i = lastIndex(stack, 'a'); if (i > 0) stack.length = i; }
      start(sp.open, sp.attrs);
    } else if (sp.close) {
      const i = lastIndex(stack, sp.close);
      if (i < 1) continue;   // nothing of that kind is open: the closer is ignored
      const again = stack.slice(i + 1).filter((e) => e.tag === 'strong' || e.tag === 'em');
      stack.length = i;
      for (const e of again) start(e.tag, e.attrs);
    }
  }
  flush();
  return out;
}
const lastIndex = (stack, tag) => { for (let i = stack.length - 1; i > 0; i--) if (stack[i].tag === tag) return i; return -1; };
const decode = (attrs) => Object.fromEntries(Object.entries(attrs).map(([k, v]) => [k, unesc(v)]));

const joinBr = (lines) => lines.flatMap((nodes, i) => (i ? [h('br'), ...nodes] : nodes));

function blocks(text) {
  const L = String(text).replace(/\r/g, '').split('\n'), out = [];
  let i = 0, para = [];
  const flush = () => { if (para.length) { out.push(h('p', null, joinBr(para.map(inline)))); para = []; } };
  const cells = (l) => l.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map((c) => inline(c.trim()));
  while (i < L.length) {
    const l = L[i];
    if (/^\s*```/.test(l)) {
      flush();
      const b = [];
      i++;
      while (i < L.length && !/^\s*```/.test(L[i])) b.push(L[i++]);
      i++;
      out.push(h('pre', null, h('code', null, b.join('\n').replace(/\u0000/g, '') || null)));
      continue;
    }
    const m = /^(#{1,4})\s+(.*)$/.exec(l);
    if (m) { flush(); out.push(h('div', { class: 'chat-h chat-h' + m[1].length }, inline(m[2]))); i++; continue; }
    if (l.includes('|') && i + 1 < L.length && /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(L[i + 1])) {
      flush();
      const rows = [h('tr', null, cells(l).map((c) => h('th', null, c)))];
      i += 2;
      while (i < L.length && L[i].includes('|') && L[i].trim()) { rows.push(h('tr', null, cells(L[i]).map((c) => h('td', null, c)))); i++; }
      out.push(h('div', { class: 'chat-tw' }, h('table', null, h('tbody', null, rows))));
      continue;
    }
    if (/^\s*([-*+]|\d+[.)])\s+/.test(l)) {
      flush();
      const ord = /^\s*\d/.test(l), it = [];
      while (i < L.length && (/^\s*([-*+]|\d+[.)])\s+/.test(L[i]) || (/^\s{2,}\S/.test(L[i]) && it.length))) {
        const x = /^\s*(?:[-*+]|\d+[.)])\s+(.*)$/.exec(L[i]);
        if (x) it.push(x[1]); else it[it.length - 1] += ' ' + L[i].trim();
        i++;
      }
      out.push(h(ord ? 'ol' : 'ul', null, it.map((t) => h('li', null, inline(t)))));
      continue;
    }
    if (/^\s*>/.test(l)) {
      flush();
      const q = [];
      while (i < L.length && /^\s*>/.test(L[i])) q.push(L[i++].replace(/^\s*>\s?/, ''));
      out.push(h('blockquote', null, joinBr(q.map(inline))));
      continue;
    }
    if (!l.trim()) { flush(); i++; continue; }
    para.push(l);
    i++;
  }
  flush();
  return out;
}

/// The Markdown text as DOM nodes (a fragment), ready to append.
export function renderMarkdown(text) {
  const out = document.createDocumentFragment();
  out.append(...blocks(text));
  return out;
}
