import { type Severity, type TimelineEvent, type SearchAst } from './timeline-types.js';
export declare const FIELDS: readonly ['kind', 'source', 'severity', 'scope', 'since', 'before', 'run', 'ask', 'msg', 'session', 'decision'];
export type Field = typeof FIELDS[number] | `attr.${string}`;
export interface Term {
    neg: boolean;
    /** absent: free text */
    field?: Field;
    /** severity only */
    op?: '=' | '>=' | '>' | '<=' | '<';
    value: string;
    /** since and before: the time read (ms) */
    time?: number;
}
export interface ParsedSearch {
    terms: Term[];
    warnings: string[];
}
/** a time: 15m, 2h, 3d, 1w back from now; or a date or date-time, local unless it has a zone */
export declare function readTime(v: string, now: number): number | undefined;
export declare function parseSearch(q: string, now?: number): ParsedSearch;
/** The parse as the query carries it: the same field twice (positive) is one term of either; free text, severity and
 *  each negation are terms of their own. */
export declare function toAst(p: ParsedSearch): SearchAst;
/** what the component sends: the parse, the range narrowed by since: and before:, and what couldn't be read */
export declare function compileSearch(q: string, now: number, from: number, to: number): {
    where: SearchAst;
    from: number;
    to: number;
    warnings: string[];
};
/** The parsed search (as a query carries it) as a test of one event. sensitive: "source.attr" names free text never
 *  looks in. */
export declare function matchAst(ast: SearchAst | undefined, sensitive?: Iterable<string>): (e: TimelineEvent) => boolean;
/** the search as typed, as a test of one event */
export declare const matcher: (p: ParsedSearch, sensitive?: Iterable<string>) => (e: TimelineEvent) => boolean;
/** the range since: and before: narrow [from, to) to (never wider) */
export declare function rangeOf(p: ParsedSearch, from: number, to: number): {
    from: number;
    to: number;
};
/** where the free text (positive terms) hits a line: [start, end) ranges, merged, in order */
export declare function highlights(p: ParsedSearch, line: string): [number, number][];
/** a severity filter as a set (for facets) */
export declare const severities: (min: Severity) => ("debug" | "error" | "info" | "notice" | "warning")[];
