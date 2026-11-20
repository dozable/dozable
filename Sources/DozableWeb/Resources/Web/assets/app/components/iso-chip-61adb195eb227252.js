// components/iso-chip — THE isolation chip: "micro VM", "fenced", "unfenced", "elsewhere" — a link to the isolation guide
// at that choice (#/guide/isolation/ID), so every chip says what it means. Every view that shows where an agent runs draws
// it through here (agent-frame's agentChips, the side panel, the Agents tab, Agents / Bots, the Add a worker page). A word
// that names no choice (an adopted session with none recorded: "on this Mac") stays a plain chip.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { isolationIdOf } from '../core/isolation-eeb96279e071283f.js';
import { guideHash } from '../core/routes-ce13c8979e42e1cc.js';

/// `word`: the chip's text; `cls`: its class suffix (`ws-iso-<cls>`, default the word with dashes) — a recorded isolation
/// (`vm`, `fenced`, …) names the choice when the word does not (Agents / Bots: "fenced on this Mac").
export function isolationChip(word, cls) {
  const id = isolationIdOf(word) || isolationIdOf(cls);
  const attrs = { class: 'ws-iso ws-iso-' + (cls || String(word).replace(/ /g, '-')), 'data-iso': word };
  if (!id) return h('span', attrs, word);
  return h('a', { ...attrs, href: guideHash(id), 'data-iso-guide': id, title: 'Where it runs: what “' + word + '” means' }, word);
}
