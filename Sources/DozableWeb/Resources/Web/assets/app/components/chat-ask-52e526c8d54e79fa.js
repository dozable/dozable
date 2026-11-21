// components/chat-ask — an ask drawn as its decision card in chat: its title and reason, each question a fieldset with
// its options lettered A–J (radios for one, checkboxes for several with how many to pick), "Something else" opening a
// field for the decider's own words when the question takes them, Skip for an optional question; Answer, and Decline with
// its reason inline (never a modal); a state line. Questions stacked (at most 5); what the person chose is kept per ask
// across redraws (the live `ask` event draws the card again). A closed ask shows only what was chosen and how it ended;
// a read-only one no control and one line why. The keyboard: Tab through the controls, the arrows in a radio group,
// Space toggles a checkbox, a letter key picks that option while focus is on that question's control (never in a text
// field), Enter on Answer or ⌘/Ctrl+Enter anywhere in the card sends when the answer is complete, Escape in a text field
// goes back to its option; after sending, focus is on the state line. It answers only through core/asks.js. Every word
// in it is the asker's untrusted text, drawn as text.
import { state } from '../core/state-716ecb2258797bb6.js';
import { viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { answerAsk, askName, canAnswer } from '../core/asks-8c636ed83ecfc048.js';
import { cap } from '../core/chat-format-bc877d395788e64c.js';
import { isRemote } from '../core/session-c08e22e67d4efa2a.js';
import { chatNote } from './chat-note-7d9b58ce10feea44.js';
import { h } from '../dom/h-f853cc7eb6672c45.js';

const LETTERS = 'ABCDEFGHIJ';
const drafts = new Map();   // msg_id → { q: { [questionId]: { opts: [ids], other: bool, text, skip } }, declining, why }

function draftOf(id) {
  if (!drafts.has(id)) drafts.set(id, { q: {}, declining: false, why: '' });
  return drafts.get(id);
}
function qDraft(d, qid) { return d.q[qid] || (d.q[qid] = { opts: [], other: false, text: '', skip: false }); }

/// "expires in 3 h" — what is left of it.
function left(at) {
  const t = Date.parse(at || '');
  if (!t) return '';
  const s = Math.max(0, Math.round((t - Date.now()) / 1000));
  return 'expires in ' + (s >= 86400 ? Math.floor(s / 86400) + ' d' : s >= 3600 ? Math.floor(s / 3600) + ' h' : s >= 60 ? Math.floor(s / 60) + ' min' : s + ' s');
}

function pickRule(q) {
  if (!q.multi) return '';
  return q.min === q.max ? 'Pick ' + q.min : 'Pick ' + q.min + ' to ' + q.max;
}

/// How an ask ended, in one line.
function endLine(m) {
  const a = m.ask, d = a.decision || {}, me = viewer();
  const by = d.by === me ? 'you' : cap(d.by || '?') + (d.decider_role ? ' (decider role)' : '');
  if (a.state === 'decided') return (d.declined ? 'declined by ' : 'decided by ') + by;
  if (a.state === 'expired') return 'expired · answer: decline';
  if (a.state === 'withdrawn') return 'withdrawn';
  return '';
}

/// Why this person sees no controls (nil: they can answer).
function readOnlyWhy(m) {
  const a = m.ask, me = viewer();
  if (isRemote()) return "Answered in this Mac's own browser";
  if (a.no_decider) return 'No decider is left: it expires to decline';
  if (m.from === me) return 'You asked this';
  if (!(a.deciders || []).includes(me)) return 'Only ' + (a.deciders || []).map(cap).join(', ') + ' can answer';
  return 'This browser may read chat but not write in it';
}

/// The answers the draft makes, or why it is not complete yet.
function answersOf(a, d) {
  const out = [];
  for (const q of a.questions) {
    const x = qDraft(d, q.id);
    if (x.skip && q.optional) { out.push({ questionId: q.id, skipped: true }); continue; }
    const text = x.other || !q.options.length ? x.text.trim() : '';
    const n = x.opts.length;
    const name = a.questions.length > 1 ? (q.header || q.question || q.id) : 'the question';
    if (!n && !text) return { why: 'Answer ' + name + (q.optional ? ', or skip it' : '') };
    if (q.multi && n && (n < q.min || n > q.max)) return { why: pickRule(q) + ' for ' + name };
    out.push({ questionId: q.id, options: x.opts.slice(), text });
  }
  return { answers: out };
}

/// The card for an ask message `m` in `room`.
export function askCard(m) {
  const a = m.ask, id = m.msg_id, d = draftOf(id);
  const open = (a.state || 'open') === 'open';
  const able = open && canAnswer(m);
  const card = h('section', { class: 'chat-ask' + (open ? ' is-open' : ' is-closed') + (able ? '' : ' is-readonly'), 'data-ask': id,
    'aria-label': 'Ask ' + askName(m) + ' from ' + cap(m.from) });
  card.append(h('div', { class: 'chat-ask-head' }, h('span', { class: 'chat-ask-badge' }, 'Ask ' + askName(m)),
    h('span', { class: 'chat-ask-title' }, String(a.question || ''))));
  if (a.reason) card.append(h('p', { class: 'chat-ask-reason' }, 'Why: ' + String(a.reason)));
  const status = h('p', { class: 'chat-ask-state', role: 'status', 'aria-live': 'polite', tabindex: '-1' });
  const answerBtn = able ? h('button', { type: 'button', class: 'btn btn-primary chat-ask-answer' }, 'Answer') : null;

  function refresh() {
    if (!answerBtn) return;
    const r = answersOf(a, d);
    answerBtn.disabled = !r.answers;
    answerBtn.title = r.answers ? 'Send your answer' : r.why;
  }

  async function send(body) {
    status.classList.remove('is-bad');
    status.textContent = 'Sending…';
    for (const el of card.querySelectorAll('button, input, textarea')) el.disabled = true;
    const r = await answerAsk({ room: state.chat.room, ask: askName(m), ...body });
    status.focus();
    if (r.ok) { drafts.delete(id); status.textContent = body.decline ? 'declined by you' : 'decided by you'; return; }
    for (const el of card.querySelectorAll('button, input, textarea')) el.disabled = false;
    refresh();
    status.classList.add('is-bad');
    status.textContent = r.refused;
    chatNote(r.refused, true);
  }

  a.questions.forEach((q, qi) => {
    const x = qDraft(d, q.id);
    const dec = open ? null : (a.decision && (a.decision.answers || []).find((y) => y.question_id === q.id));
    const legendText = (a.questions.length > 1 ? 'Question ' + (qi + 1) + ' of ' + a.questions.length + (q.header ? ' · ' + q.header : '') + ': ' : '')
      + String(q.question || a.question || '') + (q.optional ? ' (optional)' : '');
    const fs = h('fieldset', { class: 'chat-ask-q', 'data-q': q.id }, h('legend', { class: 'chat-ask-legend' }, legendText));
    if (!open || !able) {
      // Closed: only what was chosen. Read-only and open: the options, lettered, with no control.
      if (!open) {
        if (dec && dec.skipped) fs.append(h('p', { class: 'chat-ask-chosen' }, 'skipped'));
        else if (dec) {
          const labels = (dec.options || []).map((oid) => { const k = q.options.findIndex((o) => o.id === oid); return (k >= 0 ? LETTERS[k] + '. ' : '') + (k >= 0 ? q.options[k].label || oid : oid); });
          if (labels.length) fs.append(h('p', { class: 'chat-ask-chosen' }, labels.join(', ')));
          if (dec.text) fs.append(h('p', { class: 'chat-ask-chosen chat-ask-words' }, '“' + String(dec.text) + '”'));
        }
      } else {
        const ul = h('ul', { class: 'chat-ask-list' });
        q.options.forEach((o, k) => ul.append(h('li', { class: 'chat-ask-item' }, h('span', { class: 'chat-ask-letter' }, LETTERS[k] || ''), String(o.label || o.id))));
        if (q.options.length) fs.append(ul); else fs.append(h('p', { class: 'chat-ask-hint' }, 'Answered in words'));
      }
      card.append(fs);
      return;
    }
    const name = 'ask-' + id + '-' + q.id;
    const field = h('textarea', { class: 'chat-ask-text', rows: '2', maxlength: '4000', 'aria-label': 'Your own words' + (a.questions.length > 1 ? ' for question ' + (qi + 1) : ''),
      placeholder: q.options.length ? 'Your own words' : 'Your answer', 'data-k': q.id + ':text' });
    field.value = x.text;
    field.hidden = !!q.options.length && !x.other;
    field.addEventListener('input', () => { x.text = field.value; refresh(); });
    const controls = [];
    q.options.forEach((o, k) => {
      const input = h('input', { type: q.multi ? 'checkbox' : 'radio', name, value: o.id, 'data-k': q.id + ':' + o.id, class: 'chat-ask-input' });
      input.checked = x.opts.includes(o.id);
      input.addEventListener('change', () => {
        if (q.multi) x.opts = input.checked ? [...new Set([...x.opts, o.id])] : x.opts.filter((v) => v !== o.id);
        else { x.opts = [o.id]; x.other = false; field.hidden = true; }
        x.skip = false;
        refresh();
      });
      controls.push(input);
      fs.append(h('label', { class: 'chat-ask-opt' }, input, h('span', { class: 'chat-ask-letter', 'aria-hidden': 'true' }, LETTERS[k] || ''),
        h('span', { class: 'chat-ask-label' }, String(o.label || o.id), o.description ? h('span', { class: 'chat-ask-desc' }, String(o.description)) : null,
          o.id === q.recommended ? h('span', { class: 'chat-ask-rec' }, 'recommended') : null)));
    });
    let other = null;
    if (q.options.length && q.free_text) {
      other = h('input', { type: q.multi ? 'checkbox' : 'radio', name, value: '', 'data-k': q.id + ':other', class: 'chat-ask-input' });
      other.checked = x.other;
      other.addEventListener('change', () => {
        x.other = other.checked;
        if (!q.multi && other.checked) x.opts = [];
        field.hidden = !x.other;
        x.skip = false;
        refresh();
        if (x.other) field.focus();
      });
      controls.push(other);
      fs.append(h('label', { class: 'chat-ask-opt' }, other, h('span', { class: 'chat-ask-letter', 'aria-hidden': 'true' }), h('span', { class: 'chat-ask-label' }, 'Something else')));
    }
    if (q.multi) fs.append(h('p', { class: 'chat-ask-hint' }, pickRule(q)));
    if (q.free_text || !q.options.length) fs.append(field);
    field.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && other) { e.preventDefault(); e.stopPropagation(); other.focus(); }
    });
    if (q.optional) {
      const skip = h('input', { type: 'checkbox', 'data-k': q.id + ':skip', class: 'chat-ask-input' });
      skip.checked = x.skip;
      skip.addEventListener('change', () => { x.skip = skip.checked; refresh(); });
      fs.append(h('label', { class: 'chat-ask-opt chat-ask-skip' }, skip, h('span', { class: 'chat-ask-label' }, 'Skip this question')));
    }
    // A letter key picks that option while focus is on one of this question's own controls (never in a text field).
    fs.addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey || e.target.tagName === 'TEXTAREA' || !controls.includes(e.target)) return;
      const k = LETTERS.indexOf(String(e.key).toUpperCase());
      if (k < 0 || k >= q.options.length || String(e.key).length !== 1) return;
      e.preventDefault();
      const input = controls[k];
      input.focus();
      if (q.multi) input.checked = !input.checked; else input.checked = true;
      input.dispatchEvent(new Event('change'));
    });
    card.append(fs);
  });

  if (able) {
    const why = h('input', { type: 'text', class: 'chat-ask-why', maxlength: '4000', placeholder: 'Why (optional)', 'aria-label': 'Why you decline (optional)', 'data-k': 'why' });
    why.value = d.why;
    why.addEventListener('input', () => { d.why = why.value; });
    const declineRow = h('div', { class: 'chat-ask-decline' }, why);
    const confirmDecline = h('button', { type: 'button', class: 'btn chat-ask-confirm' }, 'Decline');
    const cancel = h('button', { type: 'button', class: 'btn btn-quiet' }, 'Cancel');
    declineRow.append(confirmDecline, cancel);
    declineRow.hidden = !d.declining;
    const declineBtn = h('button', { type: 'button', class: 'btn btn-quiet chat-ask-decline-btn', 'aria-expanded': String(!!d.declining) }, 'Decline…');
    declineBtn.addEventListener('click', () => { d.declining = true; declineRow.hidden = false; declineBtn.setAttribute('aria-expanded', 'true'); why.focus(); });
    cancel.addEventListener('click', () => { d.declining = false; declineRow.hidden = true; declineBtn.setAttribute('aria-expanded', 'false'); declineBtn.focus(); });
    confirmDecline.addEventListener('click', () => send({ decline: true, text: d.why.trim() || undefined }));
    why.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); confirmDecline.click(); }
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); cancel.click(); }
    });
    answerBtn.addEventListener('click', () => { const r = answersOf(a, d); if (r.answers) send({ answers: r.answers }); });
    card.append(h('div', { class: 'chat-ask-actions' }, answerBtn, declineBtn), declineRow);
    card.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey) && e.target !== why) {
        e.preventDefault();
        if (!answerBtn.disabled) answerBtn.click();
      }
    });
    refresh();
  }
  const bits = [];
  if (open) {
    bits.push(a.no_decider ? 'open · no decider left' : 'open');
    const l = left(a.expires_at);
    if (l) bits.push(l);
    if (!able) bits.push(readOnlyWhy(m));
    else if ((a.deciders || []).length > 1) bits.push('deciders: ' + a.deciders.map(cap).join(', '));
  } else {
    bits.push(endLine(m));
    if (a.state === 'decided' && a.decision && a.decision.declined && a.decision.text) bits.push('“' + String(a.decision.text) + '”');
  }
  status.textContent = bits.join(' · ');
  card.append(status);
  return card;
}

/// The card drawn again in place of `old` (the same ask), focus kept on the same control when it was in the card.
export function focusKey(el) {
  const f = document.activeElement;
  return el && f && el.contains(f) ? (f.getAttribute('data-k') || (f.classList.contains('chat-ask-state') ? 'state' : null)) : null;
}
export function refocus(el, key) {
  if (!key || !el) return;
  const t = key === 'state' ? el.querySelector('.chat-ask-state') : [...el.querySelectorAll('[data-k]')].find((x) => x.getAttribute('data-k') === key);
  if (t && !t.disabled && !t.hidden) t.focus();
}

