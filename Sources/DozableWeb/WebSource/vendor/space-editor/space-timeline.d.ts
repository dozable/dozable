// The timeline feature (space-timeline.js): give it to space-core.js's mount(). See INTEGRATION.md, "Feature modules".
import type { Feature } from './space-core.js';
declare const timeline: Feature & { readonly name: 'timeline' };
export { timeline };
export default timeline;
