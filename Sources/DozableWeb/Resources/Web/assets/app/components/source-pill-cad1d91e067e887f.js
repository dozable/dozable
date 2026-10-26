// components/source-pill — 653: whose recipe a tool is when it is NOT Dozable's — "Yours" (the person's own, in their
// settings folder) or "Community · NAME" (a catalogue the person added and confirmed) — so it is never mixed silently
// with Dozable's. A pill beside its name wherever a tool is picked (Quick try's cards and details, New Sandbox's chips),
// and the setup's "Whose recipe" section (whose, what its bake installs and reaches) before Start. Text only: the words
// come from the server's projection of a recipe that met the community requirements (plain text), and are set with
// textContent like everything else.
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';

/// The pill for `origin` (`{kind, title}` from the catalog), or null for Dozable's own.
export function sourcePill(origin) {
  if (!origin || !origin.title) return null;
  const community = origin.kind === 'community';
  return h('span', { class: 'src-pill' + (community ? ' is-community' : ' is-mine'), 'data-recipe-source': community ? 'community' : 'mine',
    title: community ? 'A community recipe — not Dozable’s' : 'Your own recipe — not Dozable’s' },
  icon(community ? 'link' : 'user-round'), String(origin.title).slice(0, 60));
}

/// The setup's "Whose recipe" body for a plan's `recipe` (`{kind, label, whose, lines}`), or [] for Dozable's own.
export function recipeWhoseNodes(recipe) {
  if (!recipe) return [];
  return [
    h('p', { class: 'src-whose', 'data-recipe-whose': '' }, sourcePill({ kind: recipe.kind, title: recipe.label.charAt(0).toUpperCase() + recipe.label.slice(1) }),
      ' ', String(recipe.whose)),
    h('ul', { class: 'src-lines', 'data-recipe-lines': '' }, ...(recipe.lines || []).map((l) => h('li', null, String(l)))),
  ];
}
