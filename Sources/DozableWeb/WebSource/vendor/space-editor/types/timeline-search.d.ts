import { type Severity, type TimelineEvent, type SearchAst, type TimelineCatalog } from './timeline-contract.js';
/** the fields every domain's search has; its link fields follow */
export declare const BASE_FIELDS: readonly ['kind', 'source', 'severity', 'scope', 'since', 'before'];
export type Field = string;
export type SearchDialect = Pick<TimelineCatalog, 'links' | 'linkMatch' | 'topKinds'>;
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
/** The search language of one domain: its fields (the base ones, then its links), and
 *  - parseSearch: the query, read;
 *  - toAst: the parse, as a query carries it;
 *  - compileSearch: what the component sends: the parse, the range narrowed by since: and before:, and what couldn't
 *    be read;
 *  - matchAst: the parsed search (as a query carries it) as a test of one event (sensitive: "source.attr" names free
 *    text never looks in);
 *  - matcher: the search as typed, as a test of one event. */
export declare function searchFor(d: SearchDialect): {
    FIELDS: string[];
    parseSearch: (q: string, now?: number) => ParsedSearch;
    toAst: (p: ParsedSearch) => SearchAst;
    compileSearch: (q: string, now: number, from: number, to: number) => {
        where: SearchAst;
        from: number;
        to: number;
        warnings: string[];
    };
    matchAst: (ast: SearchAst | undefined, sensitive?: Iterable<string>) => (e: TimelineEvent) => boolean;
    matcher: (p: ParsedSearch, sensitive?: Iterable<string>) => (e: TimelineEvent) => boolean;
};
export type Search = ReturnType<typeof searchFor>;
/** the range since: and before: narrow [from, to) to (never wider) */
export declare function rangeOf(p: ParsedSearch, from: number, to: number): {
    from: number;
    to: number;
};
/** where the free text (positive terms) hits a line: [start, end) ranges, merged, in order */
export declare function highlights(p: ParsedSearch, line: string): [number, number][];
/** a severity filter as a set (for facets) */
export declare const severities: (min: Severity) => ("debug" | "error" | "info" | "notice" | "warning")[];
