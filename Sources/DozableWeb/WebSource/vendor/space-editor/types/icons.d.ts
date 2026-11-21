export declare const ICONS: readonly ['bot', 'folder', 'box', 'key-round', 'message-square', 'activity', 'cylinder', 'shield', 'download', 'settings', 'link', 'layers', 'list', 'circle-dot', 'chevron-right', 'chevron-down', 'plus', 'pencil', 'copy', 'trash-2', 'code-xml', 'rotate-ccw', 'list-tree', 'file', 'panel-right', 'triangle-alert', 'circle-x', 'arrow-up-right', 'lock', 'external-link', 'check', 'x', 'search', 'clipboard', 'clipboard-paste', 'moon', 'lock', 'eye', 'play', 'pause', 'skip-forward', 'monkey'];
export type IconName = typeof ICONS[number];
/** our own icons, drawn in Lucide's style (24 × 24, a 2-wide round stroke, currentColor): not from its set */
export declare const OWN_ICONS: Record<string, string>;
export declare function icon(name: IconName, cls?: string): SVGSVGElement;
/** h(): the DOM, built as text only (as doz ui's dom/h.js: never HTML). */
export declare function h<K extends keyof HTMLElementTagNameMap>(tag: K, attrs?: Record<string, unknown> | null, ...kids: (Node | string | null | undefined | false)[]): HTMLElementTagNameMap[K];
