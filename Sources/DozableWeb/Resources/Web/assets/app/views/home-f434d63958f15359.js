// views/home — Home (#/home): the workspaces (the default page).
import { h } from '../dom/h-f853cc7eb6672c45.js';

export async function viewHome() {
  return h('div', { class: 'home-page', 'data-home': '' },
    h('div', { class: 'head' }, h('h1', null, 'Home')),
    h('p', { class: 'sub' }, 'Your workspaces. Your sandboxes are under This Mac › ', h('a', { href: '#/mac/sandboxes' }, 'Sandboxes'), '.'));
}
