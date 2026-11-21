// The text feature (space-text.js): give it to space-core.js's mount(). See INTEGRATION.md, "Feature modules".
import type { Feature } from './space-core.js';
declare const text: Feature & { readonly name: 'text' };
export { text };
export default text;
