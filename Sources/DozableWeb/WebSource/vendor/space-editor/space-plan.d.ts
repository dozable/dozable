// The plan feature (space-plan.js): give it to space-core.js's mount(). See INTEGRATION.md, "Feature modules".
import type { Feature } from './space-core.js';
declare const plan: Feature & { readonly name: 'plan' };
export { plan };
export default plan;
