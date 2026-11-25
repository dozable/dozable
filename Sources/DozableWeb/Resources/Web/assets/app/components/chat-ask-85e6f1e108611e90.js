// components/chat-ask — an ask drawn as its decision card in chat: its title and reason, then each question (stacked, at
// most 5): its header as a chip and "Question 2 of 3 · optional", its text (left out when it is the title), how many to
// pick for a multi-select (above the rows), its options as full-width rows lettered A–J (a native radio or checkbox in
// each, out of sight but focusable), "Something else" the next letter when the question takes words (its field under
// the row), Skip for an optional question; a footer with Decline (quiet, its reason inline — never a modal) and Answer;
// the meta line: the state as a pill, what is left of it, who decides, and its number. Picking a row never sends; Answer
// does. What the person chose is kept per ask across redraws (the live `ask` event draws the card again). A decided ask
// shows only the rows chosen (lit) and the words; a declined one its reason; an expired or withdrawn one its question
// alone; an open one no one here can decide says so; a read-only one its rows dimmed, no control, and one line why. The
// keyboard: Tab through the controls, the arrows in a radio group, Space toggles a checkbox, a letter key picks that row
// while focus is on that question's control (never in a text field), Enter on Answer or ⌘/Ctrl+Enter anywhere in the
// card sends when the answer is complete, Escape in a text field goes back to its option; after sending, focus is on
// the state line. A refusal is said in the card in the bad tone (and in the line under the composer), and stays there
// when the card is drawn again, until the next press. It answers only through core/asks.js. Every word in it is the asker's untrusted text, drawn as text.
import { state } from '../core/state-1036883eb74b9520.js';
import { viewer } from '../core/chat-api-ec968582d97ebdcb.js';
import { answerAsk, askName, canAnswer } from '../core/asks-1c4127a16dc30ca5.js';
import { cap } from '../core/chat-format-bc877d395788e64c.js';
import { isRemote } from '../core/session-d2120671b8ea9d60.js';
import { chatNote } from './chat-note-95e0cc435178e0d8.js';
import { h } from '../dom/h-f853cc7eb6672c45.js';

const LETTERS = 'ABCDEFGHIJK';
const drafts = new Map();   // msg_id → { q: { [questionId]: { opts: [ids], other: bool, text, skip } }, declining, why, refused }

function draftOf(id) {
  if (!drafts.has(id)) drafts.set(id, { q: {}, declining: false, why: '', refused: '' });
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

/// A multi-select's rule, from its min and max: "Choose 2", "Choose up to 3", "Choose 2 to 3", "Choose all that apply".
function pickRule(q) {
  if (!q.multi) return '';
  const n = q.options.length, min = Math.max(0, +q.min || 0), max = +q.max || n;
  if (min === max) return 'Choose ' + min;
  if (min <= 1 && max >= n) return 'Choose all that apply';
  if (min <= 1) return 'Choose up to ' + max;
  return 'Choose ' + min + ' to ' + max;
}

/// How an ask ended — its pill's words and tone.
function endPill(m) {
  const a = m.ask, d = a.decision || {}, me = viewer();
  const by = d.by === me ? 'you' : cap(d.by || '?') + (d.decider_role ? ' (decider role)' : '');
  // Decided in the terminal (doz workspace decide): applied or declined, said so.
  if (a.state === 'decided' && d.via === 'workspace-decide') return d.declined ? ['declined with doz workspace decide', 'is-declined'] : ['applied with doz workspace decide', 'is-decided'];
  if (a.state === 'decided') return d.declined ? ['declined by ' + by, 'is-declined'] : ['decided by ' + by, 'is-decided'];
  if (a.state === 'expired') return ['expired · answer: decline', 'is-ended'];
  if (a.state === 'withdrawn') return ['withdrawn', 'is-ended'];
  return [String(a.state || ''), 'is-ended'];
}
const pill = ([text, tone]) => h('span', { class: 'chat-ask-pill ' + tone }, text);

/// Why this person sees no controls (nil: they can answer).
function readOnlyWhy(m) {
  const a = m.ask, me = viewer();
  if (isRemote()) return "Answered in this Mac's own browser";
  if (a.no_decider) return '';
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

/// A row's letter, label, description and "(recommended)" — the same in every state.
function rowBody(o, k, q, multi) {
  return [h('span', { class: 'chat-ask-letter' + (multi ? ' is-multi' : ''), 'aria-hidden': 'true' }, LETTERS[k] || ''),
    h('span', { class: 'chat-ask-label' }, h('span', { class: 'chat-ask-name' }, String(o.label || o.id),
      o.id === q.recommended ? h('span', { class: 'chat-ask-rec' }, ' (recommended)') : null),
    o.description ? h('span', { class: 'chat-ask-desc' }, String(o.description)) : null)];
}

/// A question's head: the legend for assistive technology, its chip and step, its text unless it is the title.
function questionHead(fs, a, q, qi, open) {
  const n = a.questions.length;
  const legendText = (n > 1 ? 'Question ' + (qi + 1) + ' of ' + n + (q.header ? ' · ' + q.header : '') + ': ' : '')
    + String(q.question || a.question || '') + (q.optional ? ' (optional)' : '');
  fs.append(h('legend', { class: 'chat-ask-legend' }, legendText));
  const step = open && (n > 1 || q.optional) ? (n > 1 ? 'Question ' + (qi + 1) + ' of ' + n : '') + (q.optional ? (n > 1 ? ' · optional' : 'Optional') : '') : '';
  if (q.header || step) {
    fs.append(h('div', { class: 'chat-ask-qtop', 'aria-hidden': 'true' }, q.header ? h('span', { class: 'chat-ask-chip' }, String(q.header)) : null,
      step ? h('span', { class: 'chat-ask-step' }, step) : null));
  }
  const text = String(q.question || '');
  if (text && text !== String(a.question || '')) fs.append(h('p', { class: 'chat-ask-qtext', 'aria-hidden': 'true' }, text));
}

/// The card for an ask message `m` in `room`.
export function askCard(m) {
  const a = m.ask, id = m.msg_id, d = draftOf(id);
  const open = (a.state || 'open') === 'open';
  const able = open && canAnswer(m);
  const card = h('section', { class: 'chat-ask' + (open ? ' is-open' : ' is-closed') + (able ? '' : ' is-readonly'), 'data-ask': id,
    'aria-label': 'Ask ' + askName(m) + ' from ' + cap(m.from) });
  card.append(h('p', { class: 'chat-ask-title' }, String(a.question || '')));
  if (a.reason) card.append(h('p', { class: 'chat-ask-reason' }, 'Why: ' + String(a.reason)));
  const status = h('p', { class: 'chat-ask-state', role: 'status', 'aria-live': 'polite', tabindex: '-1' });
  // A refused answer says why in the card, and keeps saying it when the card is drawn again (the ask may have closed
  // meanwhile — its pill then says how), until the next press.
  const refused = h('p', { class: 'chat-ask-refused', hidden: !d.refused }, d.refused || '');
  const answerBtn = able ? h('button', { type: 'button', class: 'btn primary chat-ask-answer' }, 'Answer') : null;

  function refresh() {
    if (!answerBtn) return;
    const r = answersOf(a, d);
    answerBtn.disabled = !r.answers;
    answerBtn.title = r.answers ? 'Send your answer' : r.why;
  }

  async function send(body) {
    d.refused = '';
    refused.hidden = true;
    status.textContent = 'Sending…';
    for (const el of card.querySelectorAll('button, input, textarea')) el.disabled = true;
    const r = await answerAsk({ room: state.chat.room, ask: askName(m), ...body });
    status.focus();
    if (r.ok) { drafts.delete(id); status.replaceChildren(body.decline ? pill(['declined by you', 'is-declined']) : pill(['decided by you', 'is-decided'])); return; }
    for (const el of card.querySelectorAll('button, input, textarea')) el.disabled = false;
    refresh();
    paintState();
    d.refused = String(r.refused || '');
    refused.textContent = d.refused;
    refused.hidden = false;
    chatNote(r.refused, true);
  }

  const declined = !open && a.state === 'decided' && a.decision && a.decision.declined;
  a.questions.forEach((q, qi) => {
    const x = qDraft(d, q.id);
    const dec = open ? null : (a.decision && (a.decision.answers || []).find((y) => y.question_id === q.id));
    const fs = h('fieldset', { class: 'chat-ask-q', 'data-q': q.id });
    questionHead(fs, a, q, qi, open);
    if (!open) {
      // Closed: a decided ask shows only what was chosen (lit rows) and the words; any other end, the question alone.
      if (dec && dec.skipped) fs.append(h('p', { class: 'chat-ask-chosen' }, 'Skipped'));
      else if (dec && !declined) {
        for (const oid of dec.options || []) {
          const k = q.options.findIndex((o) => o.id === oid);
          fs.append(h('div', { class: 'chat-ask-opt is-chosen is-ro' }, ...rowBody(k >= 0 ? q.options[k] : { id: oid }, k, q, q.multi)));
        }
        if (dec.text) fs.append(h('p', { class: 'chat-ask-words' }, '“' + String(dec.text) + '”'));
      }
      if (fs.childElementCount > 1) card.append(fs);
      return;
    }
    if (!able) {
      // Open, read-only: the options lettered and dimmed, with no control.
      if (q.multi) fs.append(h('p', { class: 'chat-ask-hint' }, pickRule(q)));
      q.options.forEach((o, k) => fs.append(h('div', { class: 'chat-ask-opt is-ro' }, ...rowBody(o, k, q, q.multi))));
      if (!q.options.length) fs.append(h('p', { class: 'chat-ask-hint' }, 'Answered in words'));
      card.append(fs);
      return;
    }
    const name = 'ask-' + id + '-' + q.id;
    const field = h('textarea', { class: 'chat-ask-text', rows: '2', maxlength: '4000', 'aria-label': 'Your own words' + (a.questions.length > 1 ? ' for question ' + (qi + 1) : ''),
      placeholder: q.options.length ? 'Your own words' : 'Your answer', 'data-k': q.id + ':text' });
    field.value = x.text;
    field.hidden = !!q.options.length && !x.other;
    field.addEventListener('input', () => { x.text = field.value; refresh(); });
    const controls = [], rows = [];
    // A row looks chosen (.is-on) exactly while its input is checked — set here, never by :has().
    const paint = () => { controls.forEach((c, i) => rows[i].classList.toggle('is-on', c.checked)); };
    if (q.multi) fs.append(h('p', { class: 'chat-ask-hint' }, pickRule(q)));
    q.options.forEach((o, k) => {
      const input = h('input', { type: q.multi ? 'checkbox' : 'radio', name, value: o.id, 'data-k': q.id + ':' + o.id, class: 'chat-ask-input' });
      input.checked = x.opts.includes(o.id);
      input.addEventListener('change', () => {
        if (q.multi) x.opts = input.checked ? [...new Set([...x.opts, o.id])] : x.opts.filter((v) => v !== o.id);
        else { x.opts = [o.id]; x.other = false; field.hidden = true; }
        x.skip = false;
        paint();
        refresh();
      });
      controls.push(input);
      const row = h('label', { class: 'chat-ask-opt' }, input, ...rowBody(o, k, q, q.multi));
      rows.push(row);
      fs.append(row);
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
        paint();
        refresh();
        if (x.other) field.focus();
      });
      controls.push(other);
      const row = h('label', { class: 'chat-ask-opt' }, other, ...rowBody({ id: '', label: 'Something else' }, q.options.length, q, q.multi));
      rows.push(row);
      fs.append(row);
    }
    if (q.free_text || !q.options.length) fs.append(field);
    field.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && other) { e.preventDefault(); e.stopPropagation(); other.focus(); }
    });
    paint();
    if (q.optional) {
      const skip = h('input', { type: 'checkbox', 'data-k': q.id + ':skip', class: 'chat-ask-skipbox' });
      skip.checked = x.skip;
      skip.addEventListener('change', () => { x.skip = skip.checked; refresh(); });
      fs.append(h('label', { class: 'chat-ask-skip' }, skip, h('span', null, 'Skip this question')));
    }
    // A letter key picks that row while focus is on one of this question's own controls (never in a text field);
    // "Something else" has the letter after the options.
    fs.addEventListener('keydown', (e) => {
      if (e.metaKey || e.ctrlKey || e.altKey || e.target.tagName === 'TEXTAREA' || !controls.includes(e.target)) return;
      const k = LETTERS.indexOf(String(e.key).toUpperCase());
      if (k < 0 || k >= controls.length || String(e.key).length !== 1) return;
      e.preventDefault();
      const input = controls[k];
      input.focus();
      if (q.multi) input.checked = !input.checked; else input.checked = true;
      input.dispatchEvent(new Event('change'));
    });
    card.append(fs);
  });

  if (declined && a.decision.text) card.append(h('p', { class: 'chat-ask-said' }, 'Declined: “' + String(a.decision.text) + '”'));
  if (open && a.no_decider) card.append(h('p', { class: 'chat-ask-none' }, 'No one here can decide this. It expires to decline; its asker may withdraw it.'));

  if (able) {
    const why = h('input', { type: 'text', class: 'chat-ask-why', maxlength: '4000', placeholder: 'Why (optional)', 'aria-label': 'Why you decline (optional)', 'data-k': 'why' });
    why.value = d.why;
    why.addEventListener('input', () => { d.why = why.value; });
    const declineRow = h('div', { class: 'chat-ask-decline' }, why);
    const confirmDecline = h('button', { type: 'button', class: 'btn chat-ask-confirm' }, 'Decline');
    const cancel = h('button', { type: 'button', class: 'btn quiet' }, 'Cancel');
    declineRow.append(confirmDecline, cancel);
    declineRow.hidden = !d.declining;
    const declineBtn = h('button', { type: 'button', class: 'chat-ask-decline-btn', 'aria-expanded': String(!!d.declining) }, 'Decline…');
    declineBtn.addEventListener('click', () => { d.declining = true; declineRow.hidden = false; declineBtn.setAttribute('aria-expanded', 'true'); why.focus(); });
    cancel.addEventListener('click', () => { d.declining = false; declineRow.hidden = true; declineBtn.setAttribute('aria-expanded', 'false'); declineBtn.focus(); });
    confirmDecline.addEventListener('click', () => send({ decline: true, text: d.why.trim() || undefined }));
    why.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') { e.preventDefault(); confirmDecline.click(); }
      if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); cancel.click(); }
    });
    answerBtn.addEventListener('click', () => { const r = answersOf(a, d); if (r.answers) send({ answers: r.answers }); });
    card.append(h('div', { class: 'chat-ask-actions' }, declineBtn, answerBtn), declineRow);
    card.addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && (e.metaKey || e.ctrlKey) && e.target !== why) {
        e.preventDefault();
        if (!answerBtn.disabled) answerBtn.click();
      }
    });
    refresh();
  }
  // The meta line: the state (a pill, what is left, who decides or why not you), then the ask's number.
  function paintState() {
    if (!open) { status.replaceChildren(pill(endPill(m))); return; }
    status.replaceChildren(pill(['open', 'is-open']));
    const l = left(a.expires_at);
    if (l) status.append(' · ' + l);
    if (able && (a.deciders || []).length) status.append(' · for ' + a.deciders.map(cap).join(', '));
    const why = able ? '' : readOnlyWhy(m);
    if (why) status.append(' · ' + why);
  }
  paintState();
  card.append(refused, h('div', { class: 'chat-ask-meta' }, status, h('span', { class: 'chat-ask-num' }, askName(m))));
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
