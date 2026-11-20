// core/space-pictures — The workspace drawn as a picture: the space editor's renderer (vendor/space-editor, vendored at
// its commit), loaded the first time a picture is on screen — never on the first load. The loader below holds the ONE
// lazy load of the page (the compiler's lazy-import table admits exactly that literal, here, once, and rewrites it to the
// renderer's hashed path).

let renderer = null;
/// The renderer's module ({render, renderElement}); loaded once, shared. A failed load stays failed for this page
/// (the pictures show their fallback, "The picture could not be drawn").
export function loadRenderer() {
  if (!renderer) renderer = import('/vendor/space-editor/space-render.js');
  return renderer;
}
