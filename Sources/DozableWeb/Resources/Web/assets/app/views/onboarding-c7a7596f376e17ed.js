// views/onboarding — Onboarding (594; 634: the setup v2, the owner's chosen mockup onboarding-v2): Welcome (the checks
// inline) → Base image → Models & keys → GitHub & SSH → Workspace rules → Usage statistics and Stay in touch (an official
// build only) → First sandbox. Each step's title is centred over a column of the step's own width (WIZ_SIZE); the
// store's base downloads in the host from the Base image step on, its strip at the foot above the buttons (Details: a
// popover). A poll or a preparations event repaints only the strip (and the First sandbox's image line) — never a step,
// so nothing a person types is redrawn under them.
import { $, h } from '../dom/h-d909ae8eb40113fe.js';
import { icon, mark } from '../dom/icons-b4259996eee60e3d.js';
import { api } from '../core/api-3e1b927edbd234c5.js';
import { bytes, full } from '../core/format-b2e68384da8d2f36.js';
import { actOrThrow, loadPreparations, prepRunning } from '../core/operations-ff189ebd5e81fa10.js';
import { tildePath } from '../core/paths-074fefdb8b1d48aa.js';
import { loadSettings, saveSetting, secretEntryAllowed, setting } from '../core/settings-d5d1cc502b79180e.js';
import { state } from '../core/state-1378d79c750c8380.js';
import { WIZ, WIZ_SIZE, WIZ_STEPS } from '../core/wizards-b989b43058be9b08.js';
import { ACCESS_TITLES, renderAccessStep } from '../components/access-step-960e181cf05bd8af.js';
import { baseFraction, basePrep, baseStrip, stripPhase } from '../components/base-strip-198c532a58afaecf.js';
import { btn } from '../components/button-b2be2d3eaa1a3fd0.js';
import { callout } from '../components/callout-1fe929a7376b7fbc.js';
import { wizHead, wizMount } from '../components/modal-8a2a025f423bf78e.js';
import { haveList, keyPill } from '../components/model-source-4c79a17f486f0bbe.js';
import { refreshNav } from '../components/nav-cee69d57e0de2135.js';
import { pageFailure, toast } from '../components/notices-f6630ec2e36e2d1c.js';
import { rulesStep } from '../components/rules-step-44f31e5fa9a8b8ad.js';
import { stepperNode } from '../components/stepper-633627cca0db123f.js';
import { renderOps } from './operations-b5c11841ca536b78.js';
import { startQuickMade } from './quick-make-986be59c129a0ce4.js';

// The First sandbox's tools (the four published coding agents), in this order; a family by its recommended major.
const FIRST_TOOLS = ['claude-code', 'pi', 'opencode', 'codex'];

let wizTimer = null;
export function wizardStopPolling() { clearInterval(wizTimer); wizTimer = null; }
/// While the base prepares, the strip follows it (the preparations SSE event too; this is the fallback).
function wizardPoll() {
  if (wizTimer) return;
  wizTimer = setInterval(async () => {
    const w = state.wiz;
    if (state.modal !== 'onboarding' || !w || w.step <= WIZ.base) { wizardStopPolling(); return; }
    try { state.preps = await api('preparations'); } catch (_) { return; }
    renderOps();
    paintBaseStrip();
    const p = basePrep(state.preps, w.base);
    if (!p || !prepRunning(p)) wizardStopPolling();
  }, 2000);
}

export async function viewOnboarding() {
  if (!state.wiz) state.wiz = { step: 0, data: null, base: null, access: null, ignoreMode: null, config: null, busy: false, error: null };
  const w = state.wiz;
  if (!w.data || w.step === WIZ.welcome) w.data = await api('onboarding');
  if (!w.base) w.base = (w.data.base && w.data.base.id) || 'node';
  if (w.step > WIZ.base) { await loadPreparations(); wizardPoll(); }
  if (w.step >= WIZ.keys && !w.catalog) loadCatalog();
  return wizardNode();
}

/// Re-render: forced = a step change or an answer (the whole step); else only the strip (a preparation's tick).
export function renderWizard(force) {
  if (state.modal !== 'onboarding' || !state.wiz) return;
  if (!force) { paintBaseStrip(); return; }
  const before = state.wizShown;
  state.wizShown = state.wiz.step;
  wizMount(wizardNode(), before !== state.wiz.step);
}

/// 603: a step's failure is said in the step (above its buttons) and stays until the next try or step.
function wizFail(text) {
  if (!state.wiz) { pageFailure(text); return; }
  state.wiz.error = text;
  renderWizard(true);
}

export function wizGo(step) {
  if (step === WIZ.usage && !state.usageStats) step = WIZ.signup;     // an open build sends nothing: no Usage statistics step
  if (step === WIZ.signup && !state.signup) step = WIZ.first;        // a build without the sign-up skips the step
  const w = state.wiz;
  w.step = step;
  w.error = null;
  if (step > WIZ.base) { loadPreparations().then(() => paintBaseStrip()); wizardPoll(); } else wizardStopPolling();
  if (step >= WIZ.keys && !w.catalog) loadCatalog();
  renderWizard(true);
}

// ── the frame: the head, the step's centred column, the strip, the buttons ──────────────────────────────────
function shownSteps() {
  return WIZ_STEPS.map((title, i) => ({ id: String(i), title, i }))
    .filter((s) => (s.i !== WIZ.signup || state.signup) && (s.i !== WIZ.usage || state.usageStats));
}

function wizardNode() {
  const w = state.wiz, d = w.data;
  const shown = shownSteps();
  const { list: stepper, compact } = stepperNode(shown, shown.findIndex((s) => s.i === w.step),
    { go: (k) => { const i = shown[k].i; return i < w.step && i > WIZ.welcome ? () => wizGo(i) : null; } });
  const s = [stepWelcome, stepBase, stepKeys, stepAccess, stepRules, stepUsage, stepSignup, stepFirst][w.step](d, w);
  const size = s.size || WIZ_SIZE[w.step];
  return h('div', { class: 'wizard', 'data-step': String(w.step) },
    wizHead('Set up Dozable', ['Once for this Mac (store ', h('code', null, $('store-path').textContent), '). The same as ', h('code', null, 'doz onboard'), ' in a terminal.'],
      [], { list: stepper, compact }),
    h('section', { class: 'wiz-card wiz-body' },
      h('div', { class: 'w-body w2' }, h('div', { class: 'w2-col ' + size, 'data-size': size },
        h('div', { class: 'w2-head' }, h('h2', null, s.title), s.lead ? h('p', null, s.lead) : null),
        ...s.body,
        w.error ? callout('bad', { compact: true, body: w.error, attrs: { 'data-wiz-error': '' }, dismiss: () => { w.error = null; renderWizard(true); } }) : null)),
      h('div', { class: 'wm-base-slot', 'data-base-slot': '' }, w.step > WIZ.base ? stripNode() : null),
      h('div', { class: 'wiz-buttons w-foot' }, ...s.foot)));
}

const gap = () => h('span', { class: 'wiz-gap' });
const back = (step) => btn('Back', () => wizGo(step), { icon: 'arrow-left' });

function baseOf(id) {
  const d = state.wiz.data;
  return (d.bases || []).find((b) => b.id === id) || d.base || { id, title: id, reference: id, downloadBytes: 0 };
}

function stripNode() {
  const w = state.wiz;
  return baseStrip({ base: baseOf(w.base), prep: basePrep(state.preps, w.base), onRetry: () => startBase(true) });
}

/// The strip (and the First sandbox's image line) repainted in place.
function paintBaseStrip() {
  const w = state.wiz;
  const slot = document.querySelector('[data-base-slot]');
  if (!w || !slot || w.step <= WIZ.base) return;
  const n = stripNode();
  slot.replaceChildren(...(n ? [n] : []));
  const line = document.querySelector('[data-first-image]');
  if (line && w.plan) line.replaceChildren(...imageLine(w));
}

/// The base's preparation in the host: started (or joined) — never waited for here.
async function startBase(retry) {
  const w = state.wiz;
  try {
    await actOrThrow({ action: 'onboard', base: w.base });
    w.baseStarted = true;
    await loadPreparations();
    paintBaseStrip();
    wizardPoll();
  } catch (e) { if (retry) toast(e.message || String(e), true); else throw e; }
}

// ── 1 · Welcome ────────────────────────────────────────────────────────────────────────────────────────────────
function stepWelcome(d, w) {
  // 602: a store with its record opens on what was set up, with the option to run it again.
  if (d.onboarded && !w.again) {
    const o = d.onboarded;
    const b = o.base ? baseOf(o.base) : null;
    return {
      title: 'Already set up',
      lead: 'This Mac was set up on ' + full(o.date) + ' with doz ' + o.dozVersion + ' — here or as doz onboard in a terminal; it is the same.',
      body: [h('div', { class: 'ob-checks', 'data-onboarded': '' },
        h('div', { class: 'ob-check ok' }, icon('circle-check'), h('span', null, h('b', null, 'Base'), ' ',
          h('small', { 'data-onboarded-base': '' }, b ? b.title + (d.base && d.base.id === b.id && d.base.prepared ? ', ready' : ', not prepared now') : 'none prepared'))),
        h('div', { class: 'ob-check ok' }, icon('circle-check'), h('span', null, h('b', null, 'Store'), ' ', h('small', null, $('store-path').textContent)))),
        h('p', { class: 'muted' }, 'Running it again checks this Mac again and lets you change the choices; nothing already prepared is made again, and your sandboxes are not touched.')],
      foot: [btn('Go to Sandboxes', () => { state.wiz = null; location.hash = '#/overview'; }, { icon: 'box' }), gap(),
        btn('Run onboarding again', () => { w.again = true; renderWizard(true); }, { primary: true, icon: 'rotate-ccw' })],
    };
  }
  const checks = d.checks.map((c) => {
    const cls = c.status === 'ok' ? 'ok' : c.status === 'fail' && c.hard ? 'fail' : 'warn';
    return h('div', { class: 'ob-check ' + cls, 'data-check': c.check, role: 'listitem' },
      icon(cls === 'ok' ? 'circle-check' : cls === 'fail' ? 'circle-x' : 'triangle-alert'),
      h('span', null, h('b', null, c.check), c.hard && cls === 'fail' ? h('span', { class: 'tag' }, 'required') : null, ' ', h('small', null, c.detail)));
  });
  const go = btn('Get started', () => wizGo(WIZ.base), { primary: true, lg: true, icon: 'arrow-right' });
  if (d.blocked) go.disabled = true;
  return {
    title: 'Welcome',
    lead: 'Dozable runs each project in its own small Linux virtual machine on this Mac.',
    body: [
      h('p', null, 'A tool like Claude Code works there, not on your Mac. A sandbox pauses in a millisecond, hibernates to disk and wakes in a third of a second.'),
      h('p', null, 'Setting up takes a few minutes, once. The base image downloads in the background while you answer the rest, and at the end you make your first sandbox, with one tool in it.'),
      h('h3', null, 'This Mac'),
      h('div', { class: 'ob-checks', role: 'list' }, ...checks),
      d.blocked ? callout('bad', { compact: true, body: 'A required check failed — fix it, then Check again.' })
        : h('p', { class: 'muted' }, 'Every required check passes. A required one that fails stops here, with what to fix and Check again; the others only say what will not work yet.'),
    ],
    foot: [btn('Check again', async () => { w.data = await api('onboarding'); renderWizard(true); }, { quiet: true, icon: 'refresh-cw' }), gap(), go],
  };
}

// ── 2 · Base image ─────────────────────────────────────────────────────────────────────────────────────────────
function stepBase(d, w) {
  const b = baseOf(w.base);
  const ready = d.base && d.base.id === b.id && d.base.prepared;
  const others = (d.bases || []).filter((x) => x.id !== b.id);
  const other = h('details', { class: 'disclosure', 'data-other-bases': '' },
    h('summary', null, icon('chevron-down'), 'Another base — ' + others.map((x) => x.title).join(', ')),
    h('p', { class: 'muted' }, 'Only when your projects need that language’s toolchain from the start. New sandbox can still use any base later; each extra base is another download.'),
    h('div', { class: 'wiz-choices' }, ...others.map((x) => {
      const r = h('input', { type: 'radio', name: 'wiz-base', value: x.id });
      r.addEventListener('change', () => { w.base = x.id; renderWizard(true); });
      return h('label', { class: 'wiz-choice', 'data-base': x.id }, r, h('span', null, h('strong', null, x.title), h('div', { class: 'muted' }, x.useCase + ' · ↓ ' + bytes(x.downloadBytes))));
    })));
  if (w.base !== ((d.base && d.base.id) || 'node')) other.open = true;
  const chip = (t) => h('span', { class: 'ly-chip' }, t);
  const go = btn(ready ? 'Continue' : 'Download and continue', async (ev) => {
    const btnEl = ev.currentTarget;
    btnEl.disabled = true;
    try {
      if (!ready) await startBase(false);
      wizGo(WIZ.keys);
    } catch (e) { btnEl.disabled = false; wizFail(e.message || String(e)); }
  }, { primary: true, lg: true, icon: ready ? 'arrow-right' : 'download' });
  go.dataset.baseGo = '';
  return {
    title: 'Base image',
    lead: 'Every sandbox starts from one base image. Dozable downloads it once, prepares it, and keeps it ready.',
    body: [
      h('div', { class: 'ob-base', 'data-base-card': b.id }, icon('layers'),
        h('div', { class: 't' }, b.title, b.id === 'node' ? h('span', { class: 'tag' }, 'recommended') : null, ready ? h('span', { class: 'pill st-ok' }, icon('circle-check'), 'ready') : null),
        h('div', { class: 'u' }, b.useCase + '. Every sandbox also gets the developer baseline: git, ripgrep, python3, tmux, curl, jq.'),
        h('div', { class: 'm' }, h('code', null, b.reference), h('span', null, '↓ ' + bytes(b.downloadBytes)),
          h('span', null, 'ready in about ' + Math.max(1, Math.round((b.prepareSeconds || 180) / 60)) + ' min'), h('span', null, 'linux/arm64, its digest pinned'))),
      h('p', null, 'Each tool you use — Claude Code, Codex, pi, OpenCode — is added to this one base as a thin layer that shares its blocks on disk, so a second tool costs only what it adds.'),
      h('div', { class: 'ob-layers', 'aria-label': 'How the layers stack' },
        h('div', null, h('span', { class: 'ly-k' }, 'Your sandboxes'), h('span', { class: 'ly-tools' }, chip('claude'), chip('my-app'), chip('try-opencode'))),
        h('div', null, h('span', { class: 'ly-k' }, 'Tool layers'), h('span', { class: 'ly-tools' }, chip('Claude Code'), chip('Codex'), chip('pi'), chip('OpenCode'))),
        h('div', { class: 'ly-base' }, h('span', { class: 'ly-k' }, 'Base'), icon('layers'), b.title + ' — downloaded once')),
      other,
      callout('info', { compact: true, body: ready ? 'It is already prepared in this store — nothing to download.'
        : 'The download starts when you press Download and continue and runs in the background while you answer the rest — its progress sits just above these buttons from the next step on. Closing this window does not stop it.' }),
    ],
    foot: [back(WIZ.welcome), gap(), go],
  };
}

// ── 3 · Models & keys ──────────────────────────────────────────────────────────────────────────────────────────
/// The Quick try's catalog (each tool's plan: ready, the key it uses), read once from the Keys step on and again after
/// a key is saved; the accounts with it.
function loadCatalog() {
  const w = state.wiz;
  if (!w || w.catalogReading) return;
  w.catalogReading = true;
  Promise.all([api('try'), api('accounts')]).then(([c, a]) => {
    if (state.wiz !== w) return;
    w.catalog = c;
    w.accounts = a.accounts || [];
    if (state.modal === 'onboarding' && (w.step === WIZ.keys || w.step === WIZ.first)) {
      if (w.step === WIZ.first) planFirst(); else renderWizard(true);
    }
  }).catch((e) => { if (state.wiz === w) w.catalogError = e.message || String(e); }).finally(() => { w.catalogReading = false; });
}

function toolOf(w, id) {
  const agents = (w.catalog && w.catalog.agents) || [];
  // A family's name first (opencode: its recommended major — never the earlier one whose id the family's name is).
  return agents.find((a) => a.family && a.family.name === id && a.family.recommended) || agents.find((a) => a.id === id) || null;
}

/// The keys an account list holds for a source (a provider's or gateway's id).
function keysOf(w, id) {
  return (w.accounts || []).filter((a) => (a.kind === 'api-key' && id === 'anthropic') || (a.kind === 'openai-key' && id === 'openai') || (a.kind === 'key' && a.provider === id));
}

function stepKeys(d, w) {
  const claude = toolOf(w, 'claude-code'), codex = toolOf(w, 'codex');
  const signin = (tool, title, on, words) => h('div', { class: 'ob-signin', 'data-signin': title },
    tool && tool.icon ? mark(tool.icon) : icon('terminal'), h('span', { class: 't' }, title),
    h('span', { class: 'k' }, on ? h('span', { class: 'pill st-ok' }, icon('circle-check'), 'Signed in') : h('span', { class: 'pill st-off' }, icon('circle-dot'), 'Not signed in')),
    h('span', { class: 'd' }, words));
  const codexWords = d.codexMac ? 'Codex uses this Mac’s own Codex login — nothing is copied; the Mac’s Codex keeps renewing it.'
    : 'Codex uses this Mac’s own Codex login (run codex login in a terminal on this Mac — nothing is copied)' + (state.chatgptSignIn ? ', a ChatGPT sign-in (doz account add chatgpt --chatgpt)' : '') + ', or an OpenAI key.';
  const tools = FIRST_TOOLS.map((id) => toolOf(w, id)).filter(Boolean);
  const ready = w.catalog ? h('div', { class: 'ob-ready one-col', 'data-ready-tools': '' }, ...tools.map((a) => {
    const r = readiness(a, d);
    return h('div', { class: 'ob-tool' + (r.ok ? '' : ' no'), 'data-tool': a.id, 'data-ready': r.ok ? '1' : '' },
      a.icon ? mark(a.icon) : icon('terminal'), h('span', { class: 't' }, toolName(a)),
      h('span', { class: 's' }, icon(r.ok ? 'circle-check' : 'circle-dot')), h('span', { class: 'd' }, r.words));
  }))
    : h('p', { class: 'muted' }, w.catalogError ? 'The tools could not be read: ' + w.catalogError : 'Reading the tools…');
  const list = haveList({ choices: d.keyChoices || [], keysOf: (id) => keysOf(w, id), open: w.addKey,
    onAdd: (id) => { w.addKey = id; w.keyResult = null; renderWizard(true); const f = document.querySelector('[data-wiz-key]'); if (f) f.focus(); },
    addNodes: (id) => keyAddNodes(d, w, id) });
  return {
    title: 'Models & keys',
    lead: 'Every tool talks to a model. Tell Dozable which sign-ins and keys you have — a key stays in this Mac’s keychain; a sandbox only ever sees a placeholder. Nothing here is required now: a sandbox asks for what its tool needs.',
    body: [h('div', { class: 'ob-two' },
      h('div', null, h('h3', null, 'Sign-ins on this Mac'),
        h('div', { class: 'ob-signins' },
          signin(claude, 'Claude Code', d.macSignedIn, d.macSignedIn
            ? 'Claude Code uses this login. Nothing is copied — the Mac’s proxy adds it to the sandbox’s requests to Anthropic, and the Mac keeps renewing it.'
            : 'Not signed in on this Mac: an Anthropic key here, or a Claude subscription’s token (claude setup-token, then doz account add NAME --setup-token).'),
          signin(codex, 'Codex', d.codexMac, codexWords)),
        h('h3', null, 'Tools you can use now'), ready),
      h('div', null, h('h3', null, 'Keys'), list,
        w.keyResult ? h('div', { class: 'ak-result', role: 'status', 'data-key-added': w.keyResult.name }, keyPill([{ name: 'Works' }]),
          h('div', null, h('b', null, w.keyResult.name + ' is ready.'), h('div', { class: 'muted' }, w.keyResult.title + ' — it is in your login keychain; Accounts & keys has it from now on.'))) : null,
        h('p', { class: 'muted ms-small' }, 'Keep a key in 1Password, AWS or a program instead: ', h('code', null, 'doz account add NAME --provider openrouter --from op://VAULT/ITEM/FIELD'))))],
    foot: [back(WIZ.base), gap(), btn('Decide later', () => wizGo(WIZ.access), { quiet: true, icon: 'skip-forward' }), btn('Next', () => wizGo(WIZ.access), { primary: true, lg: true, icon: 'arrow-right' })],
  };
}

/// The tool's name as the key list says it ("OpenCode", never "OpenCode 2").
function toolName(a) { return a.family ? a.family.title.replace(/ \d+$/, '') : a.title; }

/// Can the tool be used now, and with what — from its Quick try plan, this Mac's sign-ins and the keys here:
/// {ok, words, account?, source?}. The catalog assumes `mac` for Claude Code; the page knows whether it is signed in.
/// A tool with a key-less source (OpenCode Zen) is usable through it while no key of another source is here.
function readiness(a, d) {
  const p = a.plan || {};
  const acc = p.account, m = p.model;
  const keyMissing = (p.problems || []).some((x) => x.code === 'key');
  if (!keyMissing && acc && acc.name === 'mac') {
    const signed = a.id === 'codex' ? d.codexMac : d.macSignedIn;
    return signed ? { ok: true, words: 'this Mac’s ' + (a.id === 'codex' ? 'Codex' : 'Claude') + ' login' }
      : { ok: false, words: a.id === 'codex' ? 'needs this Mac’s Codex login or an OpenAI key' : 'needs this Mac’s Claude login or an Anthropic key' };
  }
  if (!keyMissing) return { ok: true, words: m ? m.title + (acc && acc.name ? ' — ' + acc.name : '') : acc && acc.name ? acc.name : 'ready' };
  const usable = a.usableAccounts || [];
  if (usable.length) return { ok: true, words: usable[0].name + (usable[0].modelSource ? ' (' + usable[0].modelSource + ')' : ''), account: usable[0].name };
  const free = m && (m.offered || []).find((s) => s.accountKind === 'none');
  if (free) return { ok: true, words: 'free models (' + free.title + ')', source: free.id };
  if (a.id === 'codex') return { ok: false, words: 'needs this Mac’s Codex login or an OpenAI key' };
  const keys = (d.keyChoices || []).filter((c) => !c.keyless && c.tools.includes(toolName(a))).map((c) => c.title);
  return { ok: false, words: keys.length ? 'needs a key: ' + (keys.length > 1 ? keys.slice(0, -1).join(', ') + ' or ' + keys[keys.length - 1] : keys[0]) : 'needs a key or a sign-in' };
}

/// Under a row: its paste field (a masked field, emptied before the request) — or, with secret entry off, the command.
function keyAddNodes(d, w, id) {
  const c = (d.keyChoices || []).find((x) => x.id === id);
  if (!c) return [];
  if (!secretEntryAllowed()) {
    const flag = c.accountKind === 'api-key' ? '--api-key' : c.accountKind === 'openai-key' ? '--openai-key' : '--provider ' + id;
    return [h('div', { class: 'muted' }, 'Pasting keys here is off (ui.allow_secret_entry) — in a terminal on this Mac:'), h('code', null, 'doz account add NAME ' + flag)];
  }
  const a1 = /^[AEIOUx]/.test(c.title) ? 'an ' : 'a ';
  const field = h('input', { type: 'password', autocomplete: 'off', spellcheck: 'false', 'data-wiz-key': id, class: 'ak-in',
    placeholder: c.keyHint ? 'paste the key (' + c.keyHint + '…)' : 'paste the key', 'aria-label': 'Paste ' + a1 + c.title + ' key' });
  const save = btn('Save the key', () => saveKey(w, c, field, save), { small: true, primary: true, icon: 'key-round' });
  field.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); saveKey(w, c, field, save); } });
  return [h('div', { class: 'try-paste' }, field, save), h('div', { class: 'muted' }, 'Checked with one tiny request, then kept in this Mac’s login keychain.'),
    h('div', null, btn('Cancel', () => { w.addKey = null; renderWizard(true); }, { small: true, quiet: true, icon: 'x' }))];
}

async function saveKey(w, c, field, button) {
  const secret = field.value.trim();
  field.value = '';                                   // emptied before the request
  if (!secret || w.busy) return;
  w.busy = true;
  button.disabled = true;
  w.error = null;
  try {
    const taken = new Set((w.accounts || []).map((x) => x.name));
    let name = c.id;
    for (let n = 2; taken.has(name); n++) name = c.id + '-' + n;
    const r = await api('accounts', { method: 'POST', json: { name, kind: c.accountKind, secret, ...(c.accountKind === 'key' ? { provider: c.id } : {}) } });
    w.accounts = r.accounts || w.accounts;
    w.addKey = null;
    w.keyResult = { name, title: c.title };
    toast('Key saved — ' + name + ' (' + c.title + ')');
    // What it unlocks: the tools read again.
    w.catalog = null;
    loadCatalog();
  } catch (e) { w.error = e.message || String(e); }
  w.busy = false;
  renderWizard(true);
}

// ── 4 · GitHub & SSH ───────────────────────────────────────────────────────────────────────────────────────────
function stepAccess(d, w) {
  if (!w.access) w.access = {};
  const box = h('div', { class: 'wiz-access' });
  // 634: the Claude account is no longer this step's (Models & keys says the sign-ins); GitHub and SSH only.
  const access = renderAccessStep(box, { mode: 'onboarding', state: w.access, claude: false });
  return {
    title: 'GitHub & SSH',
    lead: 'What sandboxes may use as you — nothing is on unless you choose it, and each choice is confirmed live. One that cannot be confirmed can be skipped: the setup is never blocked.',
    body: [box],
    foot: [back(WIZ.keys), gap(), btn('Next', async (ev) => {
      const b = ev.currentTarget;
      b.disabled = true;
      try {
        if (await access.confirm()) wizGo(WIZ.rules);
        else { b.disabled = false; wizFail('Not everything is confirmed — Skip it, turn it off, or check again.'); }
      } catch (e) { b.disabled = false; wizFail(e.message || String(e)); }
    }, { primary: true, lg: true, icon: 'arrow-right' })],
  };
}

// ── 5 · Workspace rules — its Next writes the settings (the First sandbox's create needs them) ─────────────────────
function stepRules(d, w) {
  if (!w.ignoreMode) w.ignoreMode = setting('workspace.ignore_mode', 'lock');
  return {
    title: d.rulesGuide.title,
    lead: '',
    body: [rulesStep({ mode: 'onboarding', guide: d.rulesGuide, value: w.ignoreMode, onPick: (v) => { w.ignoreMode = v; } })],
    foot: [back(WIZ.access), gap(), btn('Next', async (ev) => {
      const b = ev.currentTarget;
      b.disabled = true;
      try {
        const config = { base: w.base, ignoreMode: w.ignoreMode };
        if (w.access && w.access.choices) config.access = { ...w.access.choices };
        w.config = await api('onboarding/config', { method: 'POST', json: config });
        await loadSettings();
        refreshNav();
        wizGo(WIZ.usage);
      } catch (e) { b.disabled = false; wizFail(e.message || String(e)); }
    }, { primary: true, lg: true, icon: 'arrow-right' })],
  };
}

// ── 6 · Usage statistics (an official build only) ───────────────────────────────────────────────────────────────
/// What is sent, where to see it, and ONE switch, on by default. Next saves it only when it changed (POST settings).
/// When DO_NOT_TRACK, the variable or doz ui's command line decides, the switch is shown read-only with the reason.
function stepUsage(d, w) {
  const u = state.usageStats;
  if (w.usageOn === undefined) w.usageOn = u.on;
  const input = h('input', { type: 'checkbox', role: 'switch', name: 'wiz-usage' });
  input.checked = w.usageOn;
  input.disabled = !!u.fixed;
  const choice = h('label', { class: 'wiz-choice' + (w.usageOn ? ' chosen' : ''), 'data-usage-stats': '' }, input,
    h('span', null, h('strong', null, 'Send anonymous usage statistics'),
      h('div', { class: 'muted' }, 'Change it any time: Settings › ' + u.key + '.')));
  input.addEventListener('change', () => { w.usageOn = input.checked; choice.classList.toggle('chosen', input.checked); });
  const link = h('a', { href: u.privacyPage, target: '_blank', rel: 'noopener noreferrer' }, 'the privacy policy');
  return {
    title: 'Usage statistics',
    lead: u.summary,
    body: [choice,
      u.fixed ? callout('info', { cls: 'notice', attrs: { 'data-usage-fixed': '' }, body: (u.on ? 'On' : 'Off') + ' — ' + u.fixed + '.' }) : null,
      h('p', { class: 'muted' }, 'To see exactly what is sent: ', h('code', null, u.showCommand), ' in a terminal. More in ', link, '.')],
    foot: [back(WIZ.rules), gap(), btn('Next', async (ev) => {
      const b = ev.currentTarget;
      if (u.fixed || w.usageOn === u.on) { wizGo(WIZ.signup); return; }
      b.disabled = true;
      try {
        await saveSetting(u.key, w.usageOn);
        u.on = w.usageOn;
        wizGo(WIZ.signup);
      } catch (e) { b.disabled = false; wizFail(e.message || String(e)); }
    }, { primary: true, lg: true, icon: 'arrow-right' })],
  };
}

// ── 7 · Stay in touch (an official build only) ──────────────────────────────────────────────────────────────────
const SIGNUP_INTERESTS = [['release-news', 'Release news', 'A short email when a new version is out.'],
  ['tool-news', 'Tool news', 'New and updated tools you can try in Dozable.'],
  ['early-access', 'Early access', 'Try new features before they are released.'],
  ['tips', 'Tips and tricks', 'Ways to get more out of Dozable, now and then.']];
function stepSignup(d, w) {
  const prev = state.usageStats ? WIZ.usage : WIZ.rules;
  if (w.signedUp) {
    return {
      title: 'Stay in touch',
      lead: '',
      body: [callout('ok', { cls: 'notice', attrs: { 'data-signed-up': '' }, body: w.signedUp === 'already-confirmed'
        ? 'That address is already signed up — nothing changed.'
        : 'Check your inbox: a confirmation email is on its way. Nothing else is sent until you confirm, and every email has a one-click unsubscribe.' })],
      foot: [back(prev), gap(), btn('Next', () => wizGo(WIZ.first), { primary: true, lg: true, icon: 'arrow-right' })],
    };
  }
  const email = h('input', { type: 'email', name: 'wiz-email', autocomplete: 'email', spellcheck: 'false', placeholder: 'name@example.com' });
  const boxes = SIGNUP_INTERESTS.map(([value, label, desc]) => {
    const input = h('input', { type: 'checkbox', value });
    return { input, el: h('label', { class: 'wiz-choice', 'data-interest': value }, input, h('span', null, h('strong', null, label), h('div', { class: 'muted' }, desc))) };
  });
  const error = h('div', { class: 'dlg-error', role: 'alert' });
  const send = btn('Sign up', async (ev) => {
    const b = ev.currentTarget;
    error.textContent = '';
    const interests = boxes.filter((x) => x.input.checked).map((x) => x.input.value);
    const address = email.value.trim();
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(address)) { error.textContent = 'An email address, like name@example.com.'; return; }
    if (!interests.length) { error.textContent = 'Tick at least one.'; return; }
    b.disabled = true;
    try {
      const r = await api('signup', { method: 'POST', json: { email: address, interests } });
      email.value = '';
      w.signedUp = r.status;
      renderWizard(true);
    } catch (e) { error.textContent = e.message || String(e); b.disabled = false; }
  }, { primary: true, lg: true });
  return {
    title: 'Stay in touch',
    lead: 'Optional. Release news, early access and tips from the people who make Dozable — by email, only what you tick.',
    body: [h('label', { class: 'field' }, h('span', null, 'Email'), email),
      h('fieldset', { class: 'wiz-choices' }, h('legend', null, 'What would you like?'), boxes.map((x) => x.el)),
      error,
      h('p', { class: 'muted' }, 'A confirmation email comes first; every email has a one-click unsubscribe. Your address is never linked to the usage statistics.')],
    foot: [back(prev), gap(), btn('Skip', () => wizGo(WIZ.first), { quiet: true, icon: 'skip-forward' }), send],
  };
}

// ── 8 · First sandbox — an ordinary sandbox made the quick way (the orchestrator's ruling B) ───────────────────────
// Its tool on the store's base, Standard (635; was Locked), a new empty folder named after it (or a project folder of yours) — the planner's
// `first` purpose, the same plan `doz onboard` prints (its "Same in Terminal" is the doz new that makes it). Start is the
// Quick try's own path (views/quick-make.js).
function firstChoice(w) {
  if (w.firstTool) return w.firstTool;
  const tools = FIRST_TOOLS.map((id) => toolOf(w, id)).filter(Boolean);
  const d = w.data, ok = (a) => readiness(a, d).ok;
  const pick = tools.find((a) => a.id === 'claude-code' && ok(a)) || tools.find(ok) || tools[0];
  return pick ? pick.id : null;
}

/// The plan for the chosen tool, name and folder — asked again whenever one of them changes.
async function planFirst() {
  const w = state.wiz;
  const a = toolOf(w, firstChoice(w));
  if (!a) { renderWizard(true); return; }
  w.firstTool = a.id;
  const seq = (w.planSeq = (w.planSeq || 0) + 1);
  const r = readiness(a, w.data);
  const body = { purpose: 'first', agent: a.ref || (a.family ? a.family.name : a.id) };
  if (w.firstName) body.name = w.firstName;
  if (w.folderMode === 'pick' && w.folder) body.workspace = w.folder;
  // A key it can use when its default cannot serve it; else its key-less source (free models).
  if (r.account) body.account = r.account;
  else if (r.source) body.source = r.source;
  try {
    const p = await api('plan', { method: 'POST', json: body });
    if (state.wiz !== w || seq !== w.planSeq) return;
    w.plan = p;
    w.planError = null;
  } catch (e) {
    if (state.wiz !== w || seq !== w.planSeq) return;
    w.plan = null;
    w.planError = e.message || String(e);
  }
  if (state.modal === 'onboarding' && w.step === WIZ.first) renderWizard(true);
}

function imageLine(w) {
  const p = w.plan, a = toolOf(w, w.firstTool);
  if (!p || !a) return ['—'];
  const toolTitle = a.family ? a.family.title : a.title;
  const title = (p.image && p.image.title) || p.create.image;
  const bp = basePrep(state.preps, w.base);
  const phase = stripPhase(bp, state.wiz.data.base && state.wiz.data.base.id === w.base ? state.wiz.data.base : null);
  if (p.image && p.image.state === 'prepared') return [title + ' — ready'];
  if (phase === 'download' || phase === 'prepare') {
    const pct = bp ? Math.round(baseFraction(bp) * 100) : null;
    return [title + ' — ', h('b', null, 'waits for the base' + (pct != null ? ' (' + pct + ' %)' : '')), ', then adds ' + toolTitle + ' (about a minute)'];
  }
  return [title + ' — ' + (phase === 'ready' ? 'the base is ready; adding ' + toolTitle + ' takes about a minute' : 'the base and ' + toolTitle + ' are prepared at its start')];
}

function stepFirst(d, w) {
  if (!w.catalog) {
    if (!w.catalogReading) loadCatalog();
    return { title: 'First sandbox', lead: 'Make your first sandbox, with one tool in it.', body: [h('p', { class: 'muted' }, w.catalogError ? 'The tools could not be read: ' + w.catalogError : 'Reading the tools…')],
      foot: [back(state.signup ? WIZ.signup : state.usageStats ? WIZ.usage : WIZ.rules), gap(), finishButton(w)] };
  }
  if (!w.firstTool || (!w.plan && !w.planError && !w.planAsked)) { w.planAsked = true; planFirst(); }
  const tools = FIRST_TOOLS.map((id) => toolOf(w, id)).filter(Boolean);
  const cards = h('div', { class: 'qt-results', role: 'listbox', 'aria-label': 'Tools', 'data-first-tools': '' }, ...tools.map((a) => {
    const on = a.id === w.firstTool;
    const r = readiness(a, d);
    return h('button', { type: 'button', role: 'option', class: 'qt-item' + (r.ok ? '' : ' dim'), 'aria-selected': String(on), 'data-first-tool': a.id, 'data-ready': r.ok ? '1' : '',
      on: { click: () => { if (w.firstTool === a.id) return; w.firstTool = a.id; w.firstName = null; w.plan = null; renderWizard(true); planFirst(); } } },
      a.icon ? mark(a.icon) : icon('terminal'),
      h('span', { class: 'tp' }, h('span', { class: 't' }, toolName(a)), h('span', { class: 'p' }, a.publisher || '')),
      r.ok ? h('span', { class: 'ready' }, icon('circle-check')) : h('span', { class: 'ready-gap' }),
      h('span', { class: 'need' }, (a.version ? a.version + ' · ' : '') + r.words));
  }));
  const p = w.plan;
  const a = toolOf(w, w.firstTool);
  const nameIn = h('input', { type: 'text', spellcheck: 'false', autocomplete: 'off', 'data-first-name': '', 'aria-label': 'Name' });
  nameIn.value = w.firstName || (p ? p.name : '');
  let nameTimer = null;
  nameIn.addEventListener('input', () => {
    clearTimeout(nameTimer);
    nameTimer = setTimeout(() => {
      const v = nameIn.value.trim();
      if (!/^[a-z0-9][a-z0-9-]{0,39}$/.test(v)) { w.nameError = 'The name: 1–40 of a-z 0-9 - (not starting with -).'; paintFirstProblems(w); return; }
      w.nameError = null;
      w.firstName = v;
      planFirst();
    }, 300);
  });
  const projects = p && p.workspace && w.folderMode !== 'pick' ? p.workspace : (setting('defaults.projects_dir', '~/doz-workspaces') + '/' + (w.firstName || (p ? p.name : 'NAME')));
  const radio = (mode, label, detail) => {
    const r = h('input', { type: 'radio', name: 'wiz-first-folder', value: mode });
    r.checked = (w.folderMode || 'new') === mode;
    r.addEventListener('change', () => { w.folderMode = mode; if (mode === 'new' || w.folder) planFirst(); renderWizard(true); });
    return h('label', { class: 'wiz-choice', 'data-first-folder': mode }, r, h('span', null, label, detail ? h('div', { class: 'muted' }, detail) : null));
  };
  const pickRow = w.folderMode === 'pick' ? folderPicker(w) : null;
  const facts = p ? h('dl', { class: 'qt-plan' },
    h('dt', null, 'Model'), h('dd', null, a && !readiness(a, d).ok ? readiness(a, d).words : modelWords(p)),
    h('dt', null, 'Network'), h('dd', null, 'Standard — its model, software packages and GitHub; nothing else unless you allow it'),
    h('dt', null, 'Image'), h('dd', { 'data-first-image': '' }, ...imageLine(w)),
    h('dt', null, 'Done with it?'), h('dd', null, 'Delete removes it — and the folder Dozable made for it, while that is still empty. The same for every sandbox.'),
    h('dt', null, 'Same in Terminal'), h('dd', null, h('code', { 'data-first-command': '' }, p.command))) : h('p', { class: 'muted' }, w.planError || 'Planning…');
  const openOn = w.openFiles !== undefined ? w.openFiles : setting('sandbox.open_files', true) !== false;
  const open = h('input', { type: 'checkbox', role: 'switch', 'data-first-open': '' });
  open.checked = openOn;
  open.addEventListener('change', () => { w.openFiles = open.checked; });
  const problems = h('div', { 'data-first-problems': '' });
  const start = btn('Create and start ' + (p ? p.name : '…'), () => createFirst(w, start), { primary: true, lg: true, icon: 'rocket' });
  start.dataset.firstStart = '';
  const blocking = p ? (p.problems || []) : [];
  start.disabled = !p || !a || !readiness(a, d).ok || blocking.length > 0 || !!w.nameError || w.busy;
  const waiting = (() => { const bp = basePrep(state.preps, w.base); return bp && prepRunning(bp); })();
  const body = [
    h('div', { class: 'ob-try' }, cards,
      h('div', { class: 'ob-plan' },
        h('div', { class: 'qt-sect' }, h('h3', null, 'The sandbox'),
          h('label', { class: 'field fs-name' }, h('span', null, 'Name'), nameIn),
          h('fieldset', { class: 'wiz-choices fs-folder' }, h('legend', null, 'Its folder, at ', h('code', null, '/workspace')),
            radio('new', 'A new empty folder', h('code', null, tildePath(projects))),
            radio('pick', 'A project folder on this Mac', 'the sandbox sees it live; your Mac keeps editing it as before'),
            pickRow),
          facts),
        problems,
        h('label', { class: 'ob-open' }, open, h('span', null, h('strong', null, 'Open what it makes on this Mac')),
          h('span', { class: 'd' }, 'When ' + (a ? toolName(a) : 'the tool') + ' opens a file from its folder — an .html page it made, say — it opens here, in your browser, with a notice each time. Only documents, never an app or a script. (Settings › sandbox.open_files)')))),
    whatWritten(d, w),
  ];
  setTimeout(() => paintFirstProblems(w), 0);
  return {
    title: 'First sandbox',
    lead: 'Make your first sandbox, with one tool in it: a folder of its own, a network for its model, packages and GitHub only, your keys never inside. Make more any time — Quick try, or New sandbox.',
    body,
    foot: [back(state.signup ? WIZ.signup : state.usageStats ? WIZ.usage : WIZ.rules), gap(),
      waiting && p ? h('span', { class: 'muted wiz-note' }, 'Starts now: it waits for the base, then adds ' + (a ? toolName(a) : 'the tool')) : null,
      finishButton(w), start],
  };
}

function finishButton(w) {
  return btn('Finish without a sandbox', () => { state.wiz = null; refreshNav(); location.hash = '#/overview'; }, { quiet: true, icon: 'check' });
}

function modelWords(p) {
  if (p.model) return p.model.model + ' through ' + p.model.title + ((p.problems || []).some((x) => x.code === 'key') ? ' — once its key is saved (Models & keys)' : '');
  const acc = p.account;
  if (acc && acc.name === 'mac') return 'this Mac’s login — never copied in';
  if (acc && acc.name) return acc.name + ' — the sandbox only ever sees a placeholder';
  return (p.problems || []).some((x) => x.code === 'key') ? 'needs a key or a sign-in — Models & keys adds one' : 'its own sign-in, inside the sandbox';
}

function paintFirstProblems(w) {
  const box = document.querySelector('[data-first-problems]');
  if (!box) return;
  const p = w.plan;
  const list = [...(w.nameError ? [w.nameError] : []), ...((p && p.problems) || []).filter((x) => x.code !== 'key').map((x) => x.text + (x.fix ? ' — ' + x.fix : ''))];
  box.replaceChildren(...list.map((t) => callout('bad', { compact: true, body: t })));
}

/// "A project folder on this Mac": a path typed (absolute or ~/…) or chosen with the Mac's picker.
function folderPicker(w) {
  const path = h('input', { type: 'text', spellcheck: 'false', autocomplete: 'off', placeholder: '~/code/my-project', 'aria-label': 'Project folder', 'data-first-path': '' });
  path.value = w.folder ? tildePath(w.folder) : '';
  let t = null;
  path.addEventListener('input', () => {
    clearTimeout(t);
    t = setTimeout(() => { const v = path.value.trim(); if (/^(\/|~\/)/.test(v)) { w.folder = v; planFirst(); } }, 400);
  });
  const choose = btn('Choose…', async () => {
    choose.disabled = true;
    try {
      const r = await api('workspace/choose', { method: 'POST', json: w.folder ? { start: w.folder } : {} });
      if (r && r.path) { w.folder = r.path; planFirst(); }
    } catch (e) { w.error = e.message || String(e); renderWizard(true); } finally { choose.disabled = false; }
  }, { small: true, icon: 'folder' });
  return h('div', { class: 'ws-row' }, path, choose);
}

function whatWritten(d, w) {
  const c = w.config;
  const fileLine = (label, outcome, path) => h('li', null, label + ': ', h('code', null, path ? tildePath(path) : '—'),
    outcome === 'written' ? ' — written' : outcome === 'kept' ? ' — it existed, left as it was' : ' — none');
  const keys = (w.accounts || []).filter((a) => ['api-key', 'openai-key', 'key', 'setup-token'].includes(a.kind)).map((a) => a.name);
  const signins = [d.macSignedIn ? 'this Mac’s Claude login' : null, d.codexMac ? 'this Mac’s Codex login' : null].filter(Boolean);
  const access = w.access && w.access.choices ? 'GitHub as you: ' + ({ off: 'off', read: 'read-only', push: 'read and push' }[w.access.choices.github] || w.access.choices.github) +
    ' · SSH agent: ' + w.access.choices.ssh + (w.access.skipped && w.access.skipped.size ? ' (not confirmed: ' + [...w.access.skipped].map((id) => ACCESS_TITLES[id]).join(', ') + ')' : '') : null;
  return h('details', { class: 'disclosure', 'data-what-written': '' }, h('summary', null, icon('chevron-down'), 'What setup wrote'),
    h('ul', { class: 'plain wiz-summary' },
      c ? fileLine('Settings', c.settings, c.settingsPath) : null,
      c ? fileLine('Your environment prompt template', c.promptTemplate, c.promptTemplatePath) : null,
      h('li', { 'data-wiz-projects': '' }, 'Workspace folders of new sandboxes: ', h('code', null, tildePath(setting('defaults.projects_dir', '~/doz-workspaces')) + '/<name>')),
      h('li', null, 'Base: ' + baseOf(w.base).title),
      h('li', null, 'Keys: ' + (keys.join(', ') || 'none') + ' · sign-ins: ' + (signins.join(', ') || 'none') + (access ? ' · ' + access : '') +
        (w.ignoreMode ? ' · Workspace rules: ' + w.ignoreMode : '')),
      !state.signup && state.signupPage ? h('li', { 'data-signup-link': '' }, 'Stay in touch (optional): sign up at ',
        h('a', { href: state.signupPage, target: '_blank', rel: 'noopener noreferrer' }, state.signupPage)) : null));
}

async function createFirst(w, button) {
  const p = w.plan, a = toolOf(w, w.firstTool);
  if (!p || !a || w.busy) return;
  w.busy = true;
  button.disabled = true;
  button.replaceChildren(h('span', { class: 'mini-spin', 'aria-hidden': 'true' }), h('span', null, 'Starting…'));
  try {
    // The switch saves sandbox.open_files only when it changed (as Usage statistics does).
    const was = setting('sandbox.open_files', true) !== false;
    if (w.openFiles !== undefined && w.openFiles !== was) await saveSetting('sandbox.open_files', w.openFiles);
  } catch (e) { w.busy = false; wizFail(e.message || String(e)); return; }
  const ok = await startQuickMade({ plan: p, agent: a.id, title: a.title, back: 'onboarding' });
  w.busy = false;
  if (ok && state.wiz === w) { state.wiz = null; refreshNav(); }
}
