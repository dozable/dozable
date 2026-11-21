import { SCOPE_KINDS, type Scope, type ScopeKind } from './timeline-types.js';
export interface Segment {
    kind: ScopeKind;
    name: string;
}
export declare const isScope: (s: string) => boolean;
/** a path's segments (names unescaped); throws on a path that isn't one */
export declare function parseScope(s: Scope): Segment[];
/** a name, escaped for a segment */
export declare const escapeName: (n: string) => string;
export declare const formatScope: (segs: Segment[]) => Scope;
export declare const join: (parent: Scope, kind: ScopeKind, name: string) => Scope;
/** levels below the fleet */
export declare const levelOf: (s: Scope) => number;
/** the scope's prefix at a level (itself when it is shallower) */
export declare function prefixAt(s: Scope, level: number): Scope;
export declare const parentOf: (s: Scope) => Scope;
/** segment by segment: a prefix matches itself and everything under it */
export declare const within: (s: Scope, prefix: Scope) => boolean;
/** any segment equal to seg ("sandbox:build-vm") */
export declare const hasSegment: (s: Scope, seg: string) => boolean;
export declare const kindOf: (s: Scope) => ScopeKind | 'fleet';
export declare const nameOf: (s: Scope) => string;
/** each segment may sit in its parent's kind (SCOPE_PARENTS) */
export declare function wellNested(s: Scope): boolean;
/** breadcrumbs: the fleet, then each prefix */
export declare function crumbs(s: Scope): {
    scope: Scope;
    label: string;
    kind: ScopeKind | 'fleet';
}[];
export { SCOPE_KINDS };
