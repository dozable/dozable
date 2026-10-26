// components/model-source — "Where TOOL gets its model" (618, the owner's "open router should be part of the key choices;
// needs rethink", mockup try-model-source): the tool's providers and the gateways as EQUAL rows of one list, each with
// its key status; the chosen row holds what it needs (the key in use, a choice of keys, or a paste field); then the
// model picker, fed by the host's model lists (GET /api/v1/models/SOURCE). The Quick try setup and New Sandbox both
// draw it; each keeps its own state and says what a choice does (onChoose, needFor, onPick).
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';
import { api } from '../core/api-0560a03cb0de25ef.js';
import { btn } from './button-8109d54546d946d3.js';

/// A model id a person may type (`ModelSelection.isModelID`): letters, digits and . _ : / @ + -.
export const MODEL_ID = /^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,127}$/;

/// 660: a model server on this Mac (`MacModelServer.sourceID`).
export const LOCAL = 'local';

/// 660: a port a person may name for it (`MacModelServer.ports`).
export function isLocalPort(n) { return Number.isInteger(n) && n >= 1024 && n <= 65535; }

/// 660: what the `local` source needs under its row — the port on this Mac (the known servers one click each), the
/// model by the server's own name, and what the sandbox may reach (that port only, by one name; nothing else of this
/// Mac). model: the plan's model; port: its port (null: none yet); servers: [{title, port, native, reason}]; host:
/// the name the sandbox uses; onPort(n), onModel(id) re-plan.
export function localNodes({ port, model, servers, host, onPort, onModel }) {
  const portField = h('input', { type: 'number', min: '1024', max: '65535', inputmode: 'numeric', class: 'ms-port', 'data-ms-local-port': '',
    'aria-label': 'The port of the model server on this Mac', placeholder: '11434' });
  if (port) portField.value = String(port);
  const takePort = () => { const n = Number(portField.value); if (isLocalPort(n) && n !== port) onPort(n); };
  portField.addEventListener('change', takePort);
  portField.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); takePort(); } });
  const known = (servers || []).filter((s) => s.native);
  const chips = h('div', { class: 'chips', 'data-ms-local-servers': '' },
    ...known.map((s) => btn(s.title + ' · ' + s.port, () => onPort(s.port), { small: true, quiet: s.port !== port, icon: s.port === port ? 'check' : 'cpu' })));
  const modelField = h('input', { type: 'text', spellcheck: 'false', autocomplete: 'off', 'data-ms-local-model': '',
    'aria-label': 'The model, by the server’s own name for it', placeholder: 'its name for the model — ollama list, LM Studio’s list' });
  if (model) modelField.value = model;
  const takeModel = () => { const v = modelField.value.trim(); if (MODEL_ID.test(v) && v !== model) onModel(v); };
  modelField.addEventListener('change', takeModel);
  modelField.addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); takeModel(); } });
  const notYet = (servers || []).filter((s) => !s.native);
  return [
    h('div', { class: 'ms-keyline', 'data-ms-no-key': LOCAL }, icon('circle-check'),
      h('span', null, 'No key — nothing of yours goes to it. The sandbox reaches only this port of your Mac, as ',
        h('code', null, (host || 'mac.dozable.internal') + ':' + (port || 'PORT')), '; nothing else on this Mac.')),
    h('div', { class: 'ms-field' }, h('span', null, 'Port on this Mac'), h('div', { class: 'try-paste ms-portrow' }, portField, chips)),
    h('label', { class: 'ms-field' }, h('span', null, 'Model'), modelField),
    notYet.length ? h('p', { class: 'muted ms-small', 'data-ms-local-not-yet': '' },
      'Not yet: ' + notYet.map((s) => s.title + ' — ' + (s.reason || 'needs a translator')).join(' · ')) : null,
  ];
}

/// One row's words: a gateway reaches many makers' models; a provider its own (the default named).
function what(s, own, tool) {
  if (s.gateway) return 'one key, models from many makers';
  if (s.id === LOCAL) return 'Ollama, LM Studio, llama.cpp … by its port — no key';     // 660
  if (s.accountKind === 'none') return 'free models';
  return (s.defaultModel ? 'default ' + s.defaultModel : 'its own models') + (own ? ' · ' + tool + '’s own' : '');
}

/// The key status of a source: its keys here (one named, several counted), else none yet.
export function keyPill(keys) {
  if (!keys.length) return h('span', { class: 'pill st-off', 'data-key-status': 'none' }, icon('circle-dot'), 'no key yet');
  return h('span', { class: 'pill st-ok', 'data-key-status': 'ok' }, icon('circle-check'), keys.length > 1 ? keys.length + ' keys' : keys[0].name);
}

/// 618: a source that takes no key (OpenCode Zen's free models) — its pill, and what its chosen row says.
function pillOf(s, keys) {
  if (s.accountKind === 'none') return h('span', { class: 'pill st-ok', 'data-key-status': 'none-needed' }, icon('circle-check'), 'no key needed');
  return keyPill(keys);
}

export function noKeyNodes(src) {
  return [h('div', { class: 'ms-keyline', 'data-ms-no-key': src.id }, icon('circle-check'),
    h('span', null, 'Nothing to add — no key of yours goes to ' + src.title + '. Each model’s data terms are in the list below.'))];
}

/// The source list. sources: [{id, title, gateway, defaultModel, accountKind}] (the tool's own first); keysOf(id) → [{name}];
/// chosen: an id; onChoose(id); needFor(id) → nodes under the chosen row. One source: one line, no list.
export function sourceList({ tool, sources, chosen, keysOf, onChoose, needFor, notOffered }) {
  const own = sources[0] ? sources[0].id : null;
  const nodes = [];
  if (sources.length === 1) {
    const s = sources[0];
    nodes.push(h('div', { class: 'ms-one', 'data-ms-source': s.id },
      h('span', { class: 'ms-t' }, s.title, h('span', { class: 'muted' }, ' — ' + what(s, false, tool))), pillOf(s, keysOf(s.id))));
    if (!keysOf(s.id).length && s.accountKind !== 'none') nodes.push(h('div', { class: 'ms-need ms-need-one' }, ...needFor(s.id)));
  } else {
    const row = (s) => {
      const on = s.id === chosen;
      const radio = h('input', { type: 'radio', name: 'ms-source', value: s.id, 'aria-label': s.title });
      radio.checked = on;
      radio.addEventListener('change', () => { if (radio.checked) onChoose(s.id); });
      const r = h('label', { class: 'ms-opt' + (on ? ' on' : ''), 'data-ms-source': s.id },
        radio, h('span', { class: 'ms-t' }, s.title), h('span', { class: 'ms-k' }, pillOf(s, keysOf(s.id))),
        h('span', { class: 'ms-d' }, what(s, s.id === own, tool)));
      // What the chosen source needs sits under its row — not inside the label (a click there must not re-choose).
      return on ? [r, h('div', { class: 'ms-need', 'data-ms-need': s.id }, ...needFor(s.id))] : [r];
    };
    const providers = sources.filter((s) => !s.gateway), gateways = sources.filter((s) => s.gateway);
    nodes.push(h('div', { class: 'ms-src', role: 'radiogroup', 'aria-label': 'Where ' + tool + ' gets its model', 'data-ms-list': '' },
      providers.length ? h('div', { class: 'ms-grp' }, 'Providers') : null, ...providers.flatMap(row),
      gateways.length ? h('div', { class: 'ms-grp' }, 'Gateways ', h('span', null, '— one key, models from many makers')) : null,
      ...gateways.flatMap(row)));
  }
  if (notOffered) nodes.push(h('p', { class: 'ms-notoffer', 'data-ms-not-offered': '' }, notOffered));
  return nodes;
}

/// 634 (the setup v2's Models & keys — the owner's "the Open Router key was not accepted"): every source the published
/// tools use, as Providers / Gateways / No key, each row with its key status and the tools it serves — nothing to
/// choose (the "have" mode of the list above). choices: [{id, title, gateway, keyless, tools}]; keysOf(id) → [{name}];
/// open: the id whose paste is open; onAdd(id) opens it; addNodes(id) → what goes under that row.
export function haveList({ choices, keysOf, open, onAdd, addNodes }) {
  const row = (s) => {
    const keys = keysOf(s.id);
    const k = s.keyless ? h('span', { class: 'pill st-ok', 'data-key-status': 'none-needed' }, icon('circle-check'), 'no key needed')
      : keys.length ? keyPill(keys)
      : btn('Add a key', () => onAdd(s.id), { small: true, icon: 'key-round' });
    const r = h('div', { class: 'ms-opt' + (keys.length ? ' have' : ''), 'data-ms-source': s.id },
      icon(s.keyless ? 'circle-check' : 'key-round'), h('span', { class: 'ms-t' }, s.title), h('span', { class: 'ms-k' }, k),
      h('span', { class: 'ms-d' }, s.tools.length ? 'for ' + s.tools.join(', ') : ''));
    return s.id === open ? [r, h('div', { class: 'ms-need', 'data-ms-need': s.id }, ...addNodes(s.id))] : [r];
  };
  const providers = choices.filter((s) => !s.gateway && !s.keyless), gateways = choices.filter((s) => s.gateway), free = choices.filter((s) => s.keyless);
  return h('div', { class: 'ms-src compact', 'data-ms-list': 'have' },
    providers.length ? h('div', { class: 'ms-grp' }, 'Providers') : null, ...providers.flatMap(row),
    gateways.length ? h('div', { class: 'ms-grp' }, 'Gateways ', h('span', null, '— one key, models from many makers')) : null, ...gateways.flatMap(row),
    free.length ? h('div', { class: 'ms-grp' }, 'No key') : null, ...free.flatMap(row));
}

// ── the model picker ─────────────────────────────────────────────────────────────────────────────────────────────
const LISTS = new Map();                   // source → Promise<WebModelList> (the page's life; the host keeps the day's list)
const QUERY = new Map();                   // source → what was typed (kept across a repaint)
const SHOWN = 80;

/// A new setup or step starts with an empty search (the query is kept only across that one's repaints).
export function resetModelSearch() { QUERY.clear(); }

export function modelList(source) {
  if (!LISTS.has(source)) LISTS.set(source, api('models/' + source).catch((e) => { LISTS.delete(source); throw e; }));
  return LISTS.get(source);
}

function tokens(n) { return n >= 1000000 ? (Math.round(n / 100000) / 10) + 'M' : n >= 1000 ? Math.round(n / 1000) + 'K' : String(n); }
function price(v) { return v === 0 ? 'free' : '$' + (v < 1 ? String(Number(v.toPrecision(2))) : (Math.round(v * 100) / 100).toString()); }

/// source, title, gateway: the chosen source; current: the model the plan uses; onPick(id).
export function modelPicker({ source, title, gateway, current, onPick }) {
  const box = h('div', { class: 'ms-picker', 'data-ms-picker': source });
  const search = h('input', { type: 'search', spellcheck: 'false', autocomplete: 'off', 'aria-label': 'Search models', 'data-ms-search': '',
    placeholder: 'Search ' + title + '’s models — name, maker or id' });
  search.value = QUERY.get(source) || '';
  const list = h('div', { class: 'ms-mlist', role: 'radiogroup', 'aria-label': 'Model', 'data-ms-models': '' }, h('div', { class: 'ms-empty' }, 'Reading the models…'));
  const typed = h('div', { class: 'ms-typed', hidden: true });
  const foot = h('div', { class: 'ms-foot' });
  box.append(h('div', { class: 'ms-top' }, icon('search'), search), list, typed, foot);
  let data = null;
  const draw = () => {
    if (!data) return;
    const q = search.value.trim().toLowerCase();
    QUERY.set(source, search.value);
    const hits = data.models.filter((m) => !q || (m.id + ' ' + m.name + ' ' + (m.maker || '')).toLowerCase().includes(q));
    const rows = hits.slice(0, SHOWN).map((m) => {
      const on = m.id === current;
      const radio = h('input', { type: 'radio', name: 'ms-model-' + source, value: m.id, 'aria-label': m.name });
      radio.checked = on;
      radio.addEventListener('change', () => { if (radio.checked) onPick(m.id, m.id === data.defaultModel); });
      const ctx = m.context ? tokens(m.context) + ' context' : null;
      return h('label', { class: 'ms-m' + (on ? ' on' : ''), 'data-ms-model': m.id }, radio,
        h('span', { class: 'ms-mt' }, h('span', { class: 'ms-nm' }, m.name), m.name !== m.id ? [' ', h('code', { class: 'ms-id' }, m.id)] : null,
          m.id === data.defaultModel ? h('span', { class: 'tag' }, 'default') : null),
        h('span', { class: 'ms-price' }, m.priceIn != null && m.priceOut != null ? price(m.priceIn) + ' / ' + price(m.priceOut) : '',
          m.priceIn != null && m.priceOut != null ? h('br') : null, m.priceIn != null ? 'per 1M in / out' : ''),
        h('span', { class: 'ms-meta' }, [m.maker, ctx, m.tools === false ? 'no tools' : null].filter(Boolean).join(' · ')),
        // 618: a key-less source's model — its data terms, as the source's docs state them.
        m.note ? h('span', { class: 'ms-note', 'data-ms-note': '' }, 'Data: ' + m.note) : null);
    });
    list.replaceChildren(...rows);
    if (!rows.length) list.append(h('div', { class: 'ms-empty' }, 'No model matches.'));
    if (hits.length > SHOWN) list.append(h('div', { class: 'ms-empty' }, (hits.length - SHOWN) + ' more — type to narrow'));
    // An id as typed — only when it looks like one (a gateway's are maker/name) and the list does not have it.
    const raw = search.value.trim();
    const looks = MODEL_ID.test(raw) && (!gateway || raw.includes('/'));
    if (raw && looks && !data.models.some((m) => m.id === raw)) {
      typed.hidden = false;
      typed.replaceChildren('Not in the list — ', btn('use “' + raw + '” as typed', () => { QUERY.delete(source); onPick(raw, false); }, { small: true, quiet: true, icon: 'check' }));
    } else { typed.hidden = true; typed.replaceChildren(); }
    if (current && !data.models.some((m) => m.id === current)) {
      foot.replaceChildren(h('span', null, 'Using ', h('code', null, current), ' as typed · '), footText());
    } else foot.replaceChildren(footText());
  };
  const footText = () => {
    if (!data) return '';
    if (data.kind === 'fetched') return title + '’s public model list, read on this Mac' + (data.fetchedAt ? ' ' + ago(data.fetchedAt) : '') + ' · prices per million tokens';
    if (data.kind === 'listed') return title + '’s free models as its docs list them (checked ' + (data.checked || '—') + '), with their data terms — type any other free model id it names';
    if (data.kind === 'none') return title + '’s list has not been read yet (Dozable reads it on this Mac once a day) — type any model id it names';
    return 'The model Dozable checked for ' + title + ' — type any other id it names';
  };
  search.addEventListener('input', draw);
  search.addEventListener('keydown', (ev) => {
    if (ev.key !== 'Enter') return;
    ev.preventDefault();
    const raw = search.value.trim();
    if (data && raw && (data.models.some((m) => m.id === raw) || (MODEL_ID.test(raw) && (!gateway || raw.includes('/'))))) { QUERY.delete(source); onPick(raw, raw === data.defaultModel); }
  });
  modelList(source).then((d) => { data = d; draw(); }).catch((e) => {
    data = { models: [], kind: 'default', defaultModel: null };
    draw();
    list.replaceChildren(h('div', { class: 'ms-empty' }, 'The model list could not be read (' + (e.message || String(e)) + ') — type a model id.'));
  });
  return box;
}

function ago(iso) {
  const s = (Date.now() - Date.parse(iso)) / 1000;
  if (!isFinite(s)) return '';
  if (s < 120) return 'just now';
  if (s < 7200) return Math.round(s / 60) + ' minutes ago';
  if (s < 172800) return Math.round(s / 3600) + ' hours ago';
  return Math.round(s / 86400) + ' days ago';
}

/// The command that adds a key read from where it is kept (1Password, AWS, a program) — the CLI's; the page never does.
export function sourceCommand(source, accountKind) {
  const flag = accountKind === 'api-key' ? '--api-key' : accountKind === 'openai-key' ? '--openai-key' : '--provider ' + source;
  return 'doz account add NAME ' + flag + ' --from op://VAULT/ITEM/FIELD';
}
