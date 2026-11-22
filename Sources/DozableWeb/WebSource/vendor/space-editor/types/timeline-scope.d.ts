import { type Scope, type TimelineCatalog } from './timeline-contract.js';
export interface Segment {
    kind: string;
    name: string;
}
/** what a path of this catalogue may say: isScope, parseScope (its segments, names unescaped; throws on a path that
 *  isn't one), and wellNested (each segment may sit in its parent's kind) */
export declare function scopeRules(cat: Pick<TimelineCatalog, 'kinds' | 'parents'>): {
    isScope: (s: string) => boolean;
    parseScope: (s: Scope) => Segment[];
    wellNested: (s: Scope) => boolean;
};
/** a name, escaped for a segment */
export declare const escapeName: (n: string) => string;
export declare const formatScope: (segs: Segment[]) => Scope;
export declare const join: (parent: Scope, kind: string, name: string) => Scope;
/** levels below the fleet */
export declare const levelOf: (s: Scope) => number;
/** the scope's prefix at a level (itself when it is shallower) */
export declare function prefixAt(s: Scope, level: number): Scope;
export declare const parentOf: (s: Scope) => Scope;
/** segment by segment: a prefix matches itself and everything under it */
export declare const within: (s: Scope, prefix: Scope) => boolean;
/** any segment equal to seg ("kind:name") */
export declare const hasSegment: (s: Scope, seg: string) => boolean;
export declare const kindOf: (s: Scope) => string;
export declare const nameOf: (s: Scope) => string;
/** breadcrumbs: the fleet, then each prefix */
export declare function crumbs(s: Scope): {
    scope: Scope;
    label: string;
    kind: string;
}[];
