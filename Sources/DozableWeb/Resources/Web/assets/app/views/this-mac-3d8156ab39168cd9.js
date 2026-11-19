// views/this-mac — This Mac (#/mac): everything shared by every workspace, one link per page.
import { h } from '../dom/h-f853cc7eb6672c45.js';

const PAGES = [['#/mac/here', 'On this Mac'], ['#/mac/sessions', 'Sessions'], ['#/mac/sandboxes', 'Sandboxes'], ['#/mac/templates', 'Templates'],
  ['#/mac/images', 'Images'], ['#/mac/accounts', 'Accounts & keys'], ['#/mac/resources', 'Resources'], ['#/mac/devices', 'Devices'],
  ['#/mac/logs/operations', 'Logs'], ['#/mac/doctor', 'Doctor'], ['#/mac/settings', 'Settings']];

export async function viewThisMac() {
  return h('div', { class: 'thismac-page', 'data-thismac': '' },
    h('div', { class: 'head' }, h('h1', null, 'This Mac')),
    h('ul', null, ...PAGES.map(([href, label]) => h('li', null, h('a', { href }, label)))));
}
