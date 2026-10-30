// components/setting-source — 669 (659 §0): where a setting's value came from, as a badge — recipe · default · Mac ·
// project · sandbox · env · flag (and "recorded": a sandbox's value from before 669). The same words as the CLI's SOURCE
// column; "file" is an older host's word for Mac.
import { h } from '../dom/h.js';

const WORDS = { mac: 'Mac', file: 'Mac', recipe: 'recipe', default: 'default', project: 'project', sandbox: 'sandbox', flag: 'flag', recorded: 'recorded' };
const TITLES = {
  mac: 'set on this Mac (doz.toml)', recipe: 'not set: the recipe’s own default', default: 'not set: Dozable’s default',
  project: 'set by the project (doz_project.yaml)', sandbox: 'this sandbox’s own value', flag: 'given on the command line',
  recorded: 'recorded when the sandbox was made',
};

/// The badge for a source word (`env` takes the variable's name).
export function sourceTag(source, opts = {}) {
  const s = source === 'file' ? 'mac' : source;
  return h('span', { class: 'tag src src-' + s, 'data-source': s, title: opts.title || TITLES[s] || '' },
    s === 'env' ? 'env' + (opts.environment ? ' ' + opts.environment : '') : (WORDS[s] || s));
}

/// A settings row's badge (`SettingRow`: its source, its variable, the old name it was read under).
export function sourceBadge(r) {
  return sourceTag(r.source, { environment: r.environment, title: r.migratedFrom ? 'set on this Mac, read under its old name ' + r.migratedFrom : null });
}

/// The legend: every badge with what it means.
export function sourceLegend() {
  const items = [['recipe', 'the recipe’s own'], ['default', 'Dozable’s'], ['mac', 'set in doz.toml'], ['project', 'doz_project.yaml'],
                 ['sandbox', 'one sandbox’s own'], ['env', 'the environment'], ['flag', 'a command line']];
  return h('div', { class: 'src-legend', 'data-src-legend': '' }, h('span', { class: 'muted' }, 'Where a value comes from:'),
    items.map(([s, what]) => h('span', { class: 'src-legend-item' }, sourceTag(s), what)));
}
