// components/put-in-workspace — "Put in a workspace…" for a loose agent (a sandbox, or a session on this Mac), and "Take
// out of the workspace…" for an agent in one. Each sends ONE action, exactly the CLI's command: `workspace-adopt` (doz
// workspace adopt W AGENT [--as NAME]), `workspace-new` (doz workspace new W --prompt-file F --adopt AGENT — one agent, no
// folder, reference, room or manager: chat makes the room as the CLI does) or `workspace-release` (doz workspace release
// W AGENT). Only this Mac's own browser files an agent (the server refuses another computer, `mac-only`): another one
// sees the buttons disabled and the command to copy. Filing changes only the workspace's record — the agent keeps
// running as it is; filing a RUNNING agent into a workspace that is setting up marks it started (nothing is posted).
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { actOrThrow, waitForOp } from '../core/operations-a1c19bd5aa57d920.js';
import { agentHash, workspaceHash } from '../core/routes-9e8c2eeae9c6e070.js';
import { isRemote } from '../core/session-32b26efd4b3dc47f.js';
import { state } from '../core/state-67e05db59fafd5df.js';
import { byState, loadLoose, loadWorkspace, loadWorkspaces } from '../core/workspaces-87ee868db617fbd9.js';
import { cmdLine } from './cmd-line-f0c894dc1a912086.js';
import { dialog } from './dialog-1d8e0e639a419b34.js';
import { addNote } from './notes-34d08e1aa17039c6.js';
import { pageFailure } from './notices-2ea639a7759019a9.js';
import { workspacePill } from './ws-marks-26369af31d4dbb6f.js';

/// Why this browser may not file an agent (null: it may) — only this Mac's own browser does.
export const FILING_REMOTE = 'Only from this Mac’s own browser';
export function filingRefusal() { return isRemote() ? FILING_REMOTE : null; }

/// A loose agent's name in a workspace by default: the sandbox's, or the session's.
export const agentNameOf = (agent) => (agent.startsWith('@mac/') ? agent.slice(5) : agent);

/// The commands, as a person types them in a terminal on this Mac.
export function adoptCommand(w, agent, asName) {
  return 'doz workspace adopt ' + (w || 'WORKSPACE') + ' ' + agent + (asName && asName !== agentNameOf(agent) ? ' --as ' + asName : '');
}
export function newCommand(w, agent) { return 'doz workspace new ' + (w || 'NAME') + ' --prompt-file BRIEF.md --adopt ' + agent; }
export function releaseCommand(w, name) { return 'doz workspace release ' + w + ' ' + name; }

/// A workspace's name from an agent's (the store's rule: 1–40 of a-z 0-9 -, not starting with -).
export function workspaceNameFrom(s) {
  return String(s || '').toLowerCase().replace(/[^a-z0-9-]+/g, '-').replace(/^-+/, '').slice(0, 40).replace(/-+$/, '');
}
const WORKSPACE_RULE = /^[a-z0-9][a-z0-9-]{0,39}$/;
const AGENT_RULE = /^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$/;

/// "Put in a workspace…" — opts: {running} (whether the agent runs now: what filing it does to a workspace setting up).
export async function putInWorkspace(agent, opts = {}) {
  const name = agentNameOf(agent);
  let list = state.workspaces;
  try { list = await loadWorkspaces(0); } catch (_) { /* the last list read */ }
  const choices = byState(list ? list.workspaces : []).filter((w) => w.state !== 'archived');
  const chatOn = !!(state.chat && state.chat.on);
  const remote = filingRefusal();
  const running = opts.running === true;

  // A — an existing workspace.
  let chosen = choices.length ? choices[0].name : null;
  const radios = choices.map((w) => {
    const input = h('input', { type: 'radio', name: 'piw-ws', value: w.name, 'data-piw-ws': w.name });
    input.checked = w.name === chosen;
    input.addEventListener('change', () => { if (input.checked) { chosen = w.name; sync(); } });
    return h('label', { class: 'piw-choice' + (w.state === 'finished' ? ' is-finished' : '') }, input,
      h('span', { class: 'piw-ws-name' }, w.name), workspacePill(w.state, w.words),
      w.state === 'finished' ? h('span', { class: 'muted' }, 'finished') : null);
  });
  const asInput = h('input', { type: 'text', name: 'as', autocomplete: 'off', spellcheck: 'false', 'data-piw-as': '' });
  asInput.value = name;
  const asField = h('label', { class: 'field piw-as', hidden: true }, h('span', null, 'Its name in the workspace'), asInput,
    h('small', null, 'The agent’s name there — by default its own (' + name + ').'));
  const asToggle = h('button', { type: 'button', class: 'btn sm quiet', 'data-piw-as-toggle': '',
    on: { click: () => { asField.hidden = false; asToggle.hidden = true; asInput.focus(); } } }, 'Give it another name there');
  const paneA = h('div', { class: 'piw-pane', 'data-piw-pane': 'existing' },
    choices.length ? h('div', { class: 'piw-list', role: 'radiogroup', 'aria-label': 'The workspace' }, ...radios)
      : h('p', { class: 'muted' }, 'You have not made a workspace yet — make one below.'),
    asToggle, asField);

  // B — a new workspace.
  const nameInput = h('input', { type: 'text', name: 'workspace', autocomplete: 'off', spellcheck: 'false', 'data-piw-new': '' });
  nameInput.value = workspaceNameFrom(name);
  const nameNote = h('small', { class: 'piw-check', role: 'status' });
  const brief = h('textarea', { name: 'brief', rows: 3, spellcheck: 'true', 'data-piw-brief': '' });
  brief.value = 'The work in ' + name + '.';
  const roomLine = h('p', { class: 'muted piw-room' });
  const paneB = h('div', { class: 'piw-pane', 'data-piw-pane': 'new', hidden: true },
    h('label', { class: 'field' }, h('span', null, 'Its name'), nameInput, nameNote),
    h('label', { class: 'field' }, h('span', null, 'Its brief — what the work is for'), brief,
      h('small', null, 'Prefilled — change it to say what the work is; you can edit it later on the workspace’s page.')),
    roomLine);

  let mode = choices.length ? 'existing' : 'new';
  const modeRadio = (id, label) => {
    const input = h('input', { type: 'radio', name: 'piw-mode', value: id, 'data-piw-mode': id, disabled: id === 'existing' && !choices.length ? true : null });
    input.checked = mode === id;
    input.addEventListener('change', () => { if (input.checked) { mode = id; sync(); } });
    return h('label', { class: 'piw-mode' }, input, h('span', null, label));
  };
  const cmd = h('div', { class: 'piw-cmd' });
  const show = h('details', { class: 'piw-show' }, h('summary', null, 'Show the command'), cmd);
  const hint = h('p', { class: 'piw-hint', 'data-piw-running': running ? 'yes' : 'no' }, running
    ? name + ' is running: a workspace that is setting up is marked started — nothing is posted and nothing is started.'
    : name + ' is not running: a workspace that is setting up stays setting up until it is fully set up.');
  const remoteNote = remote ? h('p', { class: 'piw-remote' }, icon('lock'), FILING_REMOTE + ' — run the command in a terminal on this Mac.') : null;
  const body = h('div', { class: 'piw', 'data-piw': agent },
    h('div', { class: 'piw-modes', role: 'radiogroup', 'aria-label': 'Where to put it' }, modeRadio('existing', 'An existing workspace'), paneA,
      modeRadio('new', 'A new workspace'), paneB),
    hint, show, remoteNote);

  function newNameProblem() {
    const v = nameInput.value.trim();
    if (!WORKSPACE_RULE.test(v)) return '1–40 characters of a-z, 0-9 and -, not starting with -';
    if (list && list.workspaces.some((w) => w.name === v)) return 'There is already a workspace ' + v + ' — choose another name, or put it in that one above';
    return null;
  }
  function sync() {
    paneA.hidden = mode !== 'existing';
    paneB.hidden = mode !== 'new';
    const v = nameInput.value.trim();
    const problem = mode === 'new' ? newNameProblem() : null;
    nameNote.textContent = problem || (v ? 'Free' : '');
    nameNote.classList.toggle('is-bad', !!problem);
    roomLine.textContent = chatOn ? 'Its room #' + (v || 'NAME') + ' is made; nothing is posted.' : 'No room: chat is off.';
    cmd.replaceChildren(cmdLine(mode === 'new' ? newCommand(v, agent) : adoptCommand(chosen, agent, asField.hidden ? null : asInput.value.trim())));
    if (d) d.querySelector('button[type=submit]').disabled = !!remote || (mode === 'new' ? !!problem || !brief.value.trim() : !chosen);
  }
  nameInput.addEventListener('input', sync);
  asInput.addEventListener('input', sync);
  brief.addEventListener('input', sync);

  let d = null;
  d = dialog('Put ' + name + ' in a workspace', 'Only the workspace’s record changes; ' + name + ' keeps running as it is.',
    [{ name: 'piw', type: 'custom', el: body, get: () => null }], 'Put in', async (_, parts) => {
      if (remote) throw new Error(FILING_REMOTE);
      let w, req;
      if (mode === 'new') {
        const problem = newNameProblem();
        if (problem) throw new Error(problem);
        w = nameInput.value.trim();
        req = { action: 'workspace-new', workspace: w, brief: brief.value, adopt: [agent] };
      } else {
        w = chosen;
        if (!w) throw new Error('Choose a workspace');
        const as = asField.hidden ? '' : asInput.value.trim();
        if (as && !AGENT_RULE.test(as)) { asField.hidden = false; throw new Error('Its name: 1–64 of letters, digits . _ - (not starting with - or .)'); }
        req = { action: 'workspace-adopt', workspace: w, agent };
        if (as && as !== name) req.as = as;
      }
      const end = await waitForOp(await actOrThrow(req), 120);
      if (!end) throw new Error('No answer yet — Operations shows how it ends.');
      if (end.state !== 'done') {
        // A name in use: open its field with the CLI's words.
        if (mode === 'existing' && /--as NAME/.test(end.text || '')) { asField.hidden = false; asToggle.hidden = true; asInput.select(); }
        throw new Error(end.text || 'It was not filed.');
      }
      await afterFiling(w);
      announce(w, end.text, mode === 'new' ? name : req.as || name);
      if (opts.onDone) opts.onDone(w);
      return undefined;
    }, { icon: 'folder-input' });
  sync();
  return d;
}

/// "Take out of the workspace…" — a plain confirmation (it is not destructive: the agent is loose again and keeps
/// running). `a`: the agent as the workspace's detail lists it. A live worker or a running manager is refused by the
/// daemon with its command (`doz worker end`, `doz workspace stop`), said in the dialog.
export function takeOut(workspace, a, opts = {}) {
  const remote = filingRefusal();
  const intro = 'Only ' + workspace + '’s record changes: ' + a.name + ' is loose again and keeps running as it is.';
  const extra = [h('div', { class: 'piw-show' }, cmdLine(releaseCommand(workspace, a.name)))];
  if (remote) extra.push(h('p', { class: 'piw-remote' }, icon('lock'), FILING_REMOTE + ' — run the command in a terminal on this Mac.'));
  const d = dialog('Take ' + a.name + ' out of ' + workspace, intro, [{ name: 'to', type: 'custom', el: h('div', null, ...extra), get: () => null }],
    'Take out', async () => {
      if (remote) throw new Error(FILING_REMOTE);
      const end = await waitForOp(await actOrThrow({ action: 'workspace-release', workspace, agent: a.name }), 120);
      if (!end) throw new Error('No answer yet — Operations shows how it ends.');
      if (end.state !== 'done') throw new Error(end.text || 'It was not taken out.');
      await afterFiling(workspace);
      addNote({ id: 'filed:' + workspace + ':' + a.name, tone: 'ok', icon: 'log-out', sticky: false, role: 'status', cls: 'toast',
        attrs: { 'data-filed': 'released' },
        body: [end.text || a.name + ' is loose again', ' ', h('a', { href: '#/mac/loose' }, 'Loose agents')] });
      if (opts.onDone) opts.onDone();
      return undefined;
    }, { icon: 'log-out' });
  if (remote) d.querySelector('button[type=submit]').disabled = true;
  return d;
}

/// After filing: the listing, the loose agents and the workspace are read again (Home, the sidebar and the pages follow).
async function afterFiling(w) {
  try { await Promise.all([loadWorkspaces(0), loadLoose(0), loadWorkspace(w, 0).catch(() => null)]); } catch (_) { /* the next hello */ }
}

/// The result line (the server's: started, or still setting up) and a link to the workspace and to the agent there.
function announce(w, text, agentName) {
  addNote({ id: 'filed:' + w + ':' + agentName, tone: 'ok', icon: 'folder-input', sticky: false, role: 'status', cls: 'toast', attrs: { 'data-filed': w },
    body: [text || agentName + ' is in ' + w, ' ', h('a', { href: workspaceHash(w), 'data-filed-open': w }, 'Open ' + w), ' · ',
      h('a', { href: agentHash(w, agentName) }, agentName + ' there')] });
}

/// A "Put in a workspace…" button (disabled with why on another computer) — `cls` for the row's own button.
export function putInButton(agent, opts = {}) {
  const why = filingRefusal();
  return h('button', { type: 'button', class: 'btn sm' + (opts.quiet ? ' quiet' : ''), 'data-put-in': agent, disabled: why ? true : null,
    title: why || 'Put ' + agentNameOf(agent) + ' in a workspace — only the workspace’s record changes',
    on: { click: () => putInWorkspace(agent, opts).catch((e) => pageFailure(e.message || String(e))) } }, icon('folder-input'), 'Put in a workspace…');
}
