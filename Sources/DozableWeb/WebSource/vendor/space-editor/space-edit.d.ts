// The edit feature (space-edit.js): give it to space-core.js's mount(). See INTEGRATION.md, "Feature modules".
import type { Feature } from './space-core.js';
declare const edit: Feature & { readonly name: 'edit' };
export { edit };
export default edit;
