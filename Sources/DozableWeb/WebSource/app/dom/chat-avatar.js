// dom/chat-avatar — a chat participant's avatar, from its `vendor:shape:colour` spec: an emoji, a letter, or a simple shape
// drawn in currentColor (its colour is a class, `chat-av-<colour>`, so no script writes a colour). Anything it does not
// know becomes the name's first letter. No picture is ever loaded from elsewhere.
import { h } from './h.js';

const COLOURS = ['blue', 'green', 'purple', 'orange', 'red', 'pink', 'teal', 'grey', 'yellow', 'white', 'brown'];
const EMOJI = { 'thumbs-up': '👍', rocket: '🚀', robot: '🤖', fire: '🔥', star: '⭐', heart: '❤️', wave: '👋', eyes: '👀', sparkles: '✨', bulb: '💡',
  check: '✅', cat: '🐱', dog: '🐶', owl: '🦉', fox: '🦊', ghost: '👻', alien: '👽', brain: '🧠', gear: '⚙️', bolt: '⚡' };
const SVGNS = 'http://www.w3.org/2000/svg';
const SHAPES = {
  circle: [['circle', { cx: 16, cy: 16, r: 14 }]],
  sphere: [['circle', { cx: 16, cy: 16, r: 14 }]],
  hexagon: [['polygon', { points: '16,3 27.3,9.5 27.3,22.5 16,29 4.7,22.5 4.7,9.5' }]],
  square: [['rect', { x: 4, y: 4, width: 24, height: 24, rx: 5 }]],
  diamond: [['rect', { x: 7, y: 7, width: 18, height: 18, rx: 3, transform: 'rotate(45 16 16)' }]],
  pill: [['rect', { x: 2, y: 8, width: 28, height: 17, rx: 8.5 }]],
  blob: [['ellipse', { cx: 16, cy: 16.5, rx: 13.5, ry: 11.5, transform: 'rotate(-16 16 16)' }]],
};

/// What the avatar dialog offers (views/chat-people.js): only what this page draws.
export const AVATAR_COLOURS = COLOURS;
export const AVATAR_SHAPES = ['circle', 'hexagon', 'square', 'diamond', 'pill', 'blob'];
export const AVATAR_EMOJI = Object.keys(EMOJI);

/// The avatar of `name` (spec as presence gives it), `size`: 'sm' (17 px), 'xs' (14 px) or the default 30 px.
export function avatar(spec, name, size) {
  const [vendor, shape, vari] = String(spec || '::').split(':');
  const colour = COLOURS.includes(vari) ? vari : '';
  const cls = ['chat-av', size ? 'chat-av-' + size : '', colour ? 'chat-av-' + colour : ''].filter(Boolean).join(' ');
  const title = name + (spec ? ' · ' + spec : '');
  if (vendor === 'emoji' && EMOJI[shape]) return h('span', { class: cls + ' chat-av-emoji', title, 'aria-hidden': 'true' }, EMOJI[shape]);
  if (SHAPES[shape]) {
    const s = document.createElementNS(SVGNS, 'svg');
    s.setAttribute('viewBox', '0 0 32 32');
    s.setAttribute('class', cls + (colour ? '' : ' chat-av-blue'));
    s.setAttribute('aria-hidden', 'true');
    const t = document.createElementNS(SVGNS, 'title');
    t.textContent = title;
    s.append(t);
    for (const [tag, attrs] of SHAPES[shape]) {
      const e = document.createElementNS(SVGNS, tag);
      for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, String(v));
      e.setAttribute('fill', 'currentColor');
      s.append(e);
    }
    return s;
  }
  // a letter on a disc: the colour asked for, else grey
  return h('span', { class: cls + ' chat-av-letter' + (colour ? '' : ' chat-av-grey'), title, 'aria-hidden': 'true' }, (String(name || '?').charAt(0) || '?').toUpperCase());
}
