// The sim feature (space-sim.js): give it to space-core.js's mount(). See INTEGRATION.md, "Feature modules".
import type { Feature } from './space-core.js';
declare const sim: Feature & { readonly name: 'sim' };
export { sim };
export default sim;
