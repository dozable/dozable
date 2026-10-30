// components/setting-matrix — a preset setting's matrix (669, owner: VS Code's "Python › Analysis: Type Checking Mode").
import { h } from '../dom/h-f853cc7eb6672c45.js';
import { icon } from '../dom/icons-9b284ea0ffb2ad04.js';

/// A table: one row per feature, one column per preset, a tick where the preset includes the feature — the drop-down that
/// picks the preset goes under it (the caller's). Text only. The column of the current value is marked (`.is-current`,
/// `--state-selected`, and the word "current" under its title: never colour alone).
/// @typedef {{ id: string, title: string, note?: string, attrs?: Object<string,string> }} MatrixRow
/// @typedef {{ id: string, title: string }} MatrixColumn
/// @param {{ label: string, rowHead?: string, rows: MatrixRow[], columns: MatrixColumn[],
///           cell: (row: MatrixRow, col: MatrixColumn) => (boolean|string), current?: string|null, attrs?: Object<string,string> }} o
///   `cell` answers true (a tick), false (blank), or a few words (a partial answer, muted: "2 of 6").
export function settingMatrix(o) {
  const cur = (c) => (c.id === o.current ? ' is-current' : '');
  const head = h('tr', null, h('th', { scope: 'col', class: 'sm-feat' }, o.rowHead || 'Feature'),
    o.columns.map((c) => h('th', { scope: 'col', class: 'sm-col' + cur(c), 'data-matrix-col': c.id },
      h('span', { class: 'sm-col-title' }, c.title), c.id === o.current ? h('span', { class: 'sm-cur' }, 'current') : null)));
  const body = o.rows.map((r) => h('tr', { 'data-matrix-row': r.id, ...(r.attrs || {}) },
    h('th', { scope: 'row', class: 'sm-feat' }, h('span', { class: 'sm-title' }, r.title), r.note ? h('span', { class: 'sm-note' }, r.note) : null),
    o.columns.map((c) => {
      const v = o.cell(r, c);
      const inner = v === true ? [icon('check'), h('span', { class: 'sr-only' }, 'yes')]
        : v ? h('span', { class: 'sm-some' }, String(v)) : h('span', { class: 'sr-only' }, 'no');
      return h('td', { class: 'sm-cell' + cur(c) + (v === true ? ' is-yes' : ''), 'data-matrix-cell': c.id }, inner);
    })));
  return h('div', { class: 'set-matrix-box', ...(o.attrs || {}) },
    h('table', { class: 'set-matrix', 'aria-label': o.label }, h('thead', null, head), h('tbody', null, body)));
}
