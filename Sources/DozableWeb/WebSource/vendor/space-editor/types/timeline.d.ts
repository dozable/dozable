import type { SpaceState } from './state-types.js';
import { SCOPE_KINDS, type Doz, type MetricPoint, type MetricRollup, type Recording, type Retention, type Result, type Scope, type ScopeKind, type SearchAst, type Severity, type TimelineEvent, type TimelineSource, type View } from './timeline-types.js';
import * as scope from './timeline-scope.js';
import { modeFor as modeForG } from './history.js';
import type * as C from './timeline-contract.js';
export interface Segment {
    kind: ScopeKind;
    name: string;
}
export declare const isScope: (s: string) => boolean;
/** a path's segments (names unescaped); throws on a path that isn't one */
export declare const parseScope: (s: Scope) => Segment[];
/** each segment may sit in its parent's kind (SCOPE_PARENTS) */
export declare const wellNested: (s: Scope) => boolean;
export declare const escapeName: typeof scope.escapeName, levelOf: typeof scope.levelOf, prefixAt: typeof scope.prefixAt, parentOf: typeof scope.parentOf, within: typeof scope.within, hasSegment: typeof scope.hasSegment, nameOf: typeof scope.nameOf;
export declare const formatScope: (segs: Segment[]) => Scope;
export declare const join: (parent: Scope, kind: ScopeKind, name: string) => Scope;
export declare const kindOf: (s: Scope) => ScopeKind | 'fleet';
export declare const crumbs: (s: Scope) => {
    scope: Scope;
    label: string;
    kind: ScopeKind | 'fleet';
}[];
export { SCOPE_KINDS };
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
export declare const readTime: (v: string, now: number) => number | undefined;
export declare const parseSearch: (q: string, now?: number) => ParsedSearch;
/** The parse as the query carries it: the same field twice (positive) is one term of either; free text, severity and
 *  each negation are terms of their own. */
export declare const toAst: (p: ParsedSearch) => SearchAst;
/** what the component sends: the parse, the range narrowed by since: and before:, and what couldn't be read */
export declare const compileSearch: (q: string, now: number, from: number, to: number) => {
    where: SearchAst;
    from: number;
    to: number;
    warnings: string[];
};
/** The parsed search (as a query carries it) as a test of one event. sensitive: "source.attr" names free text never
 *  looks in. */
export declare const matchAst: (ast: SearchAst | undefined, sensitive?: Iterable<string>) => (e: TimelineEvent) => boolean;
/** the search as typed, as a test of one event */
export declare const matcher: (p: ParsedSearch, sensitive?: Iterable<string>) => (e: TimelineEvent) => boolean;
/** the range since: and before: narrow [from, to) to (never wider) */
export declare const rangeOf: (p: ParsedSearch, from: number, to: number) => {
    from: number;
    to: number;
};
/** where the free text (positive terms) hits a line: [start, end) ranges, merged, in order */
export declare const highlights: (p: ParsedSearch, line: string) => [number, number][];
/** a severity filter as a set (for facets) */
export declare const severities: (min: Severity) => Severity[];
/** a state as the timeline may show it: never an Ask's question */
export declare function withoutQuestions(s: SpaceState | undefined): SpaceState | undefined;
export interface MemorySourceOptions {
    /** the host's now (default: the recording's catalog.now) */
    now?: number;
    /** the space's state at t, where one was recorded (run frames) */
    stateAt?(scope: Scope, t: number): Promise<SpaceState | undefined>;
}
export interface MemorySource extends TimelineSource {
    /** new or changed records, and the host's now: subscribers get them as a batch (an id, or a series, scope and t,
     *  given again replaces the first) */
    append(events: TimelineEvent[], metrics?: (MetricPoint | MetricRollup)[], now?: number): void;
    /** the user's retention for a source (what the host's settings would do) */
    setRetention(source: string, r: Retention): void;
    readonly now: number;
    readonly size: {
        events: number;
        samples: number;
    };
}
/** A Recording held in memory, answered as a host would answer query() and subscribe() (docs/timeline/README.md §8). */
export declare function memorySource(rec: Recording, o?: MemorySourceOptions): MemorySource;
export declare const toJSON: (events: TimelineEvent[], sensitive?: Iterable<string>) => string;
export declare const toCSV: (events: TimelineEvent[], sensitive?: Iterable<string>) => string;
export interface TimelineMountOptions {
    source: TimelineSource;
    /** where to start (else the URL's view, else the first host, 1 level down, the last day) */
    view?: Partial<View>;
    /** the owner's time zone (default: the viewer's) */
    tz?: string;
    /** light, dark, or the viewer's (default) */
    theme?: 'light' | 'dark' | 'system';
    /** keep the view in location.hash (#timeline=…) */
    urlState?: boolean;
    /** collapse long empty stretches into time breaks (default true; remembered per view) */
    collapseGaps?: boolean;
    /** animate a time break opening (default: unless the viewer prefers reduced motion) */
    motion?: boolean;
    openSession?(scope: Scope): void;
    openMessage?(id: string): void;
    openRun?(id: string): void;
    explainDecision?(id: string): void;
    openWorkspace?(scope: Scope): void;
    /** saved views: the host stores them */
    saveView?(v: View): void | Promise<void>;
    views?(): View[] | Promise<View[]>;
    /** the playhead moved: the state recorded there, if any (draw it on a canvas) */
    onPlayhead?(t: number, state: SpaceState | undefined): void;
    onViewChange?(v: View): void;
    /** an export: the host saves it (else the browser downloads it) */
    onExport?(name: string, text: string, type: string): void;
}
export type Mode = ReturnType<typeof modeForG>;
export declare const modeFor: (span: number, px: number) => Mode;
export declare const activityOf: (r: Result, mode: Mode, series?: Map<string, 'counter' | 'gauge'>) => [number, number][];
/** The timeline component in el (under the editor's stylesheet's root, .space-editor), over the host's source. */
export declare function mountTimeline(el: HTMLElement, o: TimelineMountOptions): {
    el: HTMLElement;
    ready: Promise<void>;
    readonly view: View;
    setView(v: Partial<View>): Promise<void>;
    setRange(t0: number, t1: number): Promise<void>;
    setPlayhead: (t: number | undefined) => Promise<void>;
    setLive: (on: boolean, go?: boolean) => void;
    setTheme: (t?: 'light' | 'dark' | 'system') => void;
    refresh: () => Promise<void>;
    internal: {
        readonly result: C.Result<Doz> | undefined;
        readonly mode: {
            kind: 'single';
        } | {
            kind: 'binned';
            bin: C.Bin;
        };
        readonly scale: import("./timeline-scale.js").TimeScale;
        readonly gaps: import("./timeline-scale.js").Gap[];
        readonly playState: SpaceState | undefined;
        readonly hits: C.TimelineEvent<Doz>[];
        readonly selected: C.TimelineEvent<Doz> | undefined;
        readonly follow: boolean;
        openCut: (from: number, to: number) => void;
        showTable: (from: number, to: number) => Promise<void>;
        rangeEvents: () => Promise<C.TimelineEvent<Doz>[]>;
        exportRange: (kind: 'json' | 'csv') => Promise<void>;
        select: (e: C.TimelineEvent<Doz> | undefined) => void;
        stepHit: (dir: 1 | -1) => void;
        drill: (s: Scope) => void;
        findHits: () => Promise<void>;
        paint: () => void;
        lines: () => ({
            kind: 'row';
            row: C.Row<Doz>;
        } | {
            kind: 'metric';
            series: string;
            unit: string;
            type: 'counter' | 'gauge';
            title: string;
        })[];
    };
    dispose(): void;
};
export type TimelineHandle = ReturnType<typeof mountTimeline>;
export type { MetricPoint, MetricRollup, Doz };
export type { Row, Query, Result } from './timeline-types.js';
