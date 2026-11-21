// The motion feature (space-motion.js): give it to space-core.js's mount(). See INTEGRATION.md, "Feature modules".
import type { Feature } from './space-core.js';
declare const motion: Feature & { readonly name: 'motion' };
export { motion };
export default motion;
