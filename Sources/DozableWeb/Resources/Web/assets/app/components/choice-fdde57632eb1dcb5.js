// components/choice — 647: a choice card (`.wiz-choice`): a label around its radio or checkbox; chosen = the accent ring.
// Its state is a class the stylesheet keys on — `.is-checked`, `.is-disabled` — never `:has()` (re-evaluated on every
// change below it, and it never fast-rejects). Set when the card is made, and kept by ONE listener as the person picks:
// a radio's group-mates (unchecked without an event of their own) are synced with it.
import { h } from '../dom/h-f853cc7eb6672c45.js';

/// A `.wiz-choice` label (`attrs` carries the class) around `input`, then the card's text.
export function choiceCard(attrs, input, ...kids) {
  const el = h('label', attrs, input, ...kids);
  syncChoice(el);
  return el;
}
function syncChoice(label) {
  const input = label.querySelector(':scope > input');
  if (!input) return;
  label.classList.toggle('is-checked', input.checked);
  label.classList.toggle('is-disabled', input.disabled);
}
const isCardInput = (i) => i instanceof HTMLInputElement && !!i.parentElement && i.parentElement.classList.contains('wiz-choice');
document.addEventListener('change', (ev) => {
  const t = ev.target;
  if (!isCardInput(t)) return;
  const group = t.type === 'radio' && t.name ? [...document.getElementsByName(t.name)] : [t];
  for (const i of group) if (isCardInput(i)) syncChoice(i.parentElement);
});
