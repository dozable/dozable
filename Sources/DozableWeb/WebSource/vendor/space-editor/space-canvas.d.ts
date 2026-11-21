// The canvas feature (space-canvas.js): give it to space-core.js's mount(). See INTEGRATION.md, "Feature modules".
import type { Feature } from './space-core.js';
declare const canvas: Feature & { readonly name: 'canvas' };
export { canvas };
export default canvas;
