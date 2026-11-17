// core/util — Small pure helpers: lists, argv splitting, guarded calls, integer checks, UTF-8.


export function lines(s) { return s.split(/[\n,]+/).map((x) => x.trim()).filter(Boolean); }
/// A command line → argv (spaces split; '…' and "…" group; \ escapes in "…"). No shell runs it.
export function splitArgs(s) {
  const out = [];
  let cur = '', q = null, any = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === q) q = null;
      else if (c === '\\' && q === '"' && i + 1 < s.length) cur += s[++i];
      else cur += c;
    } else if (c === '\'' || c === '"') { q = c; any = true; }
    else if (/\s/.test(c)) { if (cur || any) out.push(cur); cur = ''; any = false; }
    else if (c === '\\' && i + 1 < s.length) cur += s[++i];
    else cur += c;
  }
  if (q) throw new Error('an unclosed quote');
  if (cur || any) out.push(cur);
  return out;
}
export const utf8 = new TextEncoder();
export function quietly(fn, fallback) { try { return fn(); } catch (_) { return fallback; } }

// ── the frame protocol, page side: only our frames (by window), only an opaque origin, only these
// messages with typed, capped fields. Anything else is dropped and counted.
export const isInt = (v, lo, hi) => Number.isInteger(v) && v >= lo && v <= hi;

/// 636: a link from a terminal — or a chat message — is untrusted text. Only http/https, no login in it, and never this
/// Mac itself (a loopback or this page's own host): the browser bridge's rule. The URL as the browser parses it, or null.
export function safeLink(s) {
  let u;
  try { u = new URL(s); } catch (_) { return null; }
  if (u.protocol !== 'http:' && u.protocol !== 'https:') return null;
  if (u.username || u.password) return null;
  const host = u.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!host || host === 'localhost' || host.endsWith('.localhost') || host === '::1' || host === '0.0.0.0' || /^127\./.test(host)
      || host === location.hostname.replace(/^\[|\]$/g, '').toLowerCase()) return null;
  return u.href;
}
