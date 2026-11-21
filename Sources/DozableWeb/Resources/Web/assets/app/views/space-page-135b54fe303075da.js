// views/space-page — A space workspace's editor, #/w/NAME/space (web.md, "The space editor's page"). The editor's core and
// its stylesheet load the first time the page opens, through the compiler's lazy-import table; nothing of it on a first load.
import { h } from '../dom/h-f853cc7eb6672c45.js';

let core = null, styled = false;
/// The editor's core, loaded once (a failed load is tried again on the next visit).
export function loadEditor() {
  if (!core) core = import('/assets/vendor-space-editor-3d1946ae6c4b4ee7/space-core.js').catch((e) => { core = null; throw e; });
  return core;
}
/// The editor's stylesheet, linked once per document (scoped to .space-editor; left in place on leave).
export function linkEditorStyle() {
  if (styled) return;
  styled = true;
  document.head.append(h('link', { rel: 'stylesheet', href: '/assets/vendor-space-editor-3d1946ae6c4b4ee7/space-editor.css', 'data-space-editor': 'style' }));
}
