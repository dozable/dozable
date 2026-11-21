// The core's API (space-core.js): mount() with the features a host gives it. See INTEGRATION.md, "Feature modules".
import type { MountOptions, SpaceEditor } from './space-editor.js';
export type { MountOptions, SpaceEditor, Theme, SpacePlan, SpaceProblem, SpaceRisk, PlanStep, SaveResult, SpaceState, ItemState, ItemType, Lifetime, Attention, AttentionKind, AskAttention, RunSummary, RunDetail } from './space-editor.js';
export { STATES, STATE_VERSION } from './space-editor.js';

export type FeatureName = 'text' | 'canvas' | 'edit' | 'plan' | 'live' | 'motion' | 'sim' | 'timeline';
/** a feature module's default export (space-NAME.js) */
export interface Feature { readonly name: FeatureName }
export declare const FEATURE_NAMES: FeatureName[];
/** The editor with the features given: the core alone is the shell, the model, the reader and the tree, read-only unless
 *  'edit' is given. A feature not given is never loaded. */
export declare function mount(el: HTMLElement, opts?: MountOptions, features?: readonly Feature[]): SpaceEditor;
/** The features named, each by its own static dynamic import. */
export declare function loadFeatures(names: readonly FeatureName[]): Promise<Feature[]>;
/** mount() with the features named, loaded first. */
export declare function mountFeatures(el: HTMLElement, opts: MountOptions, names: readonly FeatureName[]): Promise<SpaceEditor>;
