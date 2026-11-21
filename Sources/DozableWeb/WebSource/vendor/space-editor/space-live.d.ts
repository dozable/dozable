// The live feature (space-live.js): give it to space-core.js's mount(). See INTEGRATION.md, "Feature modules".
import type { Feature } from './space-core.js';
declare const live: Feature & { readonly name: 'live' };
export { live };
export default live;
