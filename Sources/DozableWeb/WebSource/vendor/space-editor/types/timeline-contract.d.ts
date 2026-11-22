export declare const TIMELINE_VERSION = 1;
/** what a domain fills in */
export interface TimelineTypes {
    /** its scope kinds */
    kind: string;
    /** what a recorded frame holds */
    state: unknown;
    /** the boolean flags a scope's name (and its row) may carry */
    flag: string;
    /** the links an event may carry: each an id, never a text */
    links: object;
}
/** any domain's (the generic code's own view) */
export interface AnyTimeline extends TimelineTypes {
    kind: string;
    state: unknown;
    flag: never;
    links: Record<string, string | undefined>;
}
/** a scope path: "kind:name" segments, outermost first, joined by "/"; the fleet is "" */
export type Scope = string;
/** a segment's name: no "/", ":", "%" or whitespace, except %-escaped (%2F, %3A, %25, %20) */
export declare const SEGMENT_NAME = "(?:[^/:%\\s]|%[0-9A-F]{2})+";
export declare const SEVERITIES: readonly ['debug', 'info', 'notice', 'warning', 'error'];
export type Severity = typeof SEVERITIES[number];
/** an attribute's value: a scalar, never an object; a string is one short line */
export type AttrValue = string | number | boolean | null;
/** One thing that happened, at t (or over [t, t + dur) for a span). */
export interface TimelineEvent<T extends TimelineTypes = AnyTimeline> {
    /** unique within its source and stable: the same record, the same id (a later batch with this id replaces it) */
    id: string;
    /** when, in ms since 1970-01-01T00:00:00Z */
    t: number;
    /** a span's length in ms (so far, while open); absent for a mark */
    dur?: number;
    /** an ongoing span: it lasts to now (its dur, if any, is so far); a later batch gives its end */
    open?: true;
    scope: Scope;
    /** one of the catalogue's sources */
    source: string;
    /** one of its source's kinds */
    kind: string;
    severity: Severity;
    /** one line a person reads (at most 200 characters): never a message's text, a prompt, a secret, a real hostname, a
     *  folder, or a sensitive attr's value */
    summary: string;
    /** a flat map of scalars; the source's catalogue entry names the keys it may carry and which are sensitive */
    attrs: Record<string, AttrValue>;
    links: T['links'];
}
export declare const BINS: readonly ['1m', '1h', '1d'];
export type Bin = typeof BINS[number];
/** a bin's nominal width (a local day may be 23 or 25 hours long) */
export declare const BIN_MS: Record<Bin, number>;
/** one sample of a series, at t (a later batch with the same series, scope and t replaces it) */
export interface MetricPoint {
    series: string;
    scope: Scope;
    t: number;
    value: number;
}
/** a series over one bin [t, t + bin): what a coarser bin is made of (min of mins, max of maxes, sums of sums and counts) */
export interface MetricRollup {
    series: string;
    scope: Scope;
    t: number;
    bin: Bin;
    min: number;
    max: number;
    sum: number;
    count: number;
}
/** events over one bin, on one row: how the zoomed-out view draws count bars and heat strips */
export interface EventBin {
    /** the row's scope */
    scope: Scope;
    t: number;
    bin: Bin;
    count: number;
    /** count by severity (absent keys are 0) */
    severity: Partial<Record<Severity, number>>;
    /** count by kind, for the kinds present (a host may give only the top few, and say so with kindsTruncated: then the
     *  kind counts of a coarser bin can't be made from it) */
    kinds?: Record<string, number>;
    kindsTruncated?: boolean;
}
/** one test of an event */
export type Match<T extends TimelineTypes = AnyTimeline> = {
    field: 'text';
    value: string;
} | {
    field: 'kind' | 'source';
    value: string;
    prefix?: true;
} | {
    field: 'severity';
    op: 'eq' | 'ge' | 'gt' | 'le' | 'lt';
    value: Severity;
} | {
    field: 'scope';
    value: Scope;
    from: 'top' | 'segments';
} | {
    field: 'link';
    link: keyof T['links'];
    value: string;
} | {
    field: 'attr';
    key: string;
    value: string;
};
/** a term: any of its matches (the same field twice ORs), or none of them when not */
export interface AstTerm<T extends TimelineTypes = AnyTimeline> {
    not?: true;
    any: Match<T>[];
}
/** every term (different fields AND); since: and before: aren't here: they narrow the query's from and to */
export interface SearchAst<T extends TimelineTypes = AnyTimeline> {
    all: AstTerm<T>[];
}
/** days kept; null: kept until the user deletes it */
export type Days = number | null;
export interface Retention {
    /** single events (and raw metric points) */
    events: Days;
    /** rollups, by bin */
    rollups: Record<Bin, Days>;
}
export interface SeriesInfo<T extends TimelineTypes = AnyTimeline> {
    name: string;
    /** e.g. "count", "bytes", "ms", "%" */
    unit: string;
    /** counter: a count per sample, shown as sums only (its mean is meaningless); gauge: a level, shown as its min/max
     *  band and mean */
    type: 'counter' | 'gauge';
    /** the scope kind a series is recorded at */
    at: T['kind'];
    title: string;
}
export interface KindInfo {
    name: string;
    title: string;
    /** a span (it has a dur, or is open) */
    span?: boolean;
    /** named, not yet recorded */
    notYet?: boolean;
}
export interface SourceInfo<T extends TimelineTypes = AnyTimeline> {
    name: string;
    title: string;
    /** kept: the host records it today; not-yet: named in the contract, not yet recorded (the UI lists it, greyed) */
    status: 'kept' | 'not-yet';
    /** the scope kinds its events and series are recorded at */
    at: T['kind'][];
    kinds: KindInfo[];
    /** kinds taken verbatim from the host's own names: any kind matching this (the listed kinds are the known ones) */
    kindPattern?: string;
    series: SeriesInfo<T>[];
    /** the attrs its events may carry */
    attrs: string[];
    /** attrs that can name something sensitive (a remote host, a folder, free text): hidden until asked for, never in free
     *  text search, a summary or a rollup */
    sensitive?: string[];
    /** attrs naming a person: the viewer's own name is written "you" */
    people?: string[];
    /** what the contract suggests; a host may choose otherwise */
    defaultRetention: Retention;
}
/** The effective retention, per source, as the user set it: the UI says "kept 30 days" and greys out what's gone. */
export interface EffectiveRetention extends Retention {
    source: string;
    /** user: set by the user; default: the host's default */
    setBy: 'user' | 'default';
    /** the earliest t still kept, for single events and for each bin (absent: nothing kept yet) */
    keptFrom: {
        events?: number;
        rollups: Partial<Record<Bin, number>>;
    };
}
/** A scope's display: its label, the domain's flags, and the scopes it was known as before a rename (their history
 *  shows on its row). */
export type ScopeName<T extends TimelineTypes = AnyTimeline> = {
    scope: Scope;
    label: string;
    aliases?: Scope[];
} & {
    [F in T['flag']]?: boolean;
};
export interface Catalog<T extends TimelineTypes = AnyTimeline> {
    timeline: 1;
    type: 'catalog';
    /** display names, chosen by the host per machine, %-escaped in a scope: never a real hostname */
    hosts: string[];
    sources: SourceInfo<T>[];
    retention: EffectiveRetention[];
    /** labels, flags and renames */
    names?: ScopeName<T>[];
    /** the host's now: the live edge */
    now: number;
}
export interface Filters {
    source?: string[];
    kind?: string[];
    severity?: Severity[];
    /** scope prefixes (segment-wise: a prefix matches it and everything under it) */
    scope?: Scope[];
}
export interface Query<T extends TimelineTypes = AnyTimeline> {
    timeline: 1;
    type: 'query';
    scope: Scope;
    /** rows: the scopes this many levels below scope (0: one row, the scope itself) */
    depth: number;
    /** [from, to), ms; since: and before: already applied */
    from: number;
    to: number;
    /** binned: bins and rollups; absent: single events and points */
    bin?: Bin;
    /** the owner's time zone (IANA, e.g. "Australia/Sydney"): 1d bins start at its midnight, and 1h bins on its hour
     *  where its offset isn't whole hours; absent: UTC */
    tz?: string;
    /** the search, parsed by the component: what a host applies (ANDed with filters) */
    where?: SearchAst<T>;
    /** the search as typed: for display and saved views only; a host never needs to read it */
    q?: string;
    filters?: Filters;
    /** series to return (absent: every series recorded at or under the rows; empty: none) */
    series?: string[];
    /** single events per page (default 2000, at most 10000) */
    limit?: number;
    /** from a result's next: the same query, the next page */
    cursor?: string;
}
/** A row the component draws: one scope at the query's depth, with its name's flags. Events at a shallower scope than
 *  the rows go on their own scope's row, marked own. */
export type Row<T extends TimelineTypes = AnyTimeline> = {
    scope: Scope;
    /** the last segment's name, or the catalogue's label */
    label: string;
    kind: T['kind'] | 'fleet';
    /** levels below the query's scope */
    depth: number;
    own?: boolean;
    /** scopes one level below this row (the component offers to drill in when > 0) */
    children: number;
    /** events in the range, after search and filters */
    count: number;
    first?: number;
    last?: number;
} & {
    [F in T['flag']]?: boolean;
};
export interface Result<T extends TimelineTypes = AnyTimeline> {
    timeline: 1;
    type: 'result';
    rows: Row<T>[];
    /** unbinned: single events, by (t, id); spans overlapping the range are included */
    events?: TimelineEvent<T>[];
    /** binned: counts per row and bin, an event counted in the bin of its t */
    bins?: EventBin[];
    /** binned: the spans at least one bin long, so they still draw zoomed out */
    spans?: TimelineEvent<T>[];
    /** points unbinned, rollups binned (attributed to rows: sums and counts add, min of mins, max of maxes) */
    metrics: (MetricPoint | MetricRollup)[];
    /** all matching events in the range (or an estimate, said so) */
    total: number;
    totalEstimated?: boolean;
    retention: EffectiveRetention[];
    /** what of the search couldn't be read, and was searched as text (the component's parse says so; a host may add) */
    warnings?: string[];
    /** more single events: pass as cursor */
    next?: string;
}
/** What subscribe() pushes: what's new or changed since the last batch, for a live query (to moves with the host's
 *  now). An event with an id already given replaces it (an open span's end, a late field); a point with a series, scope
 *  and t already given replaces it (a minute's counters grow after the minute). On the wire, one Batch per SSE event. */
export interface Batch<T extends TimelineTypes = AnyTimeline> {
    timeline: 1;
    type: 'batch';
    events: TimelineEvent<T>[];
    metrics: (MetricPoint | MetricRollup)[];
    /** rows that appeared */
    rows?: Row<T>[];
    /** the host's now: everything up to here is in */
    now: number;
    retention?: EffectiveRetention[];
    /** resume from here after a dropped connection (the SSE event's id) */
    resume?: string;
}
/** A saved view: what the URL holds, with a name (the host stores it). */
export interface View {
    timeline: 1;
    type: 'view';
    name: string;
    scope: Scope;
    depth: number;
    /** a fixed range, or a quick one (15m, 1h, 1d, 1w, run) ending at now */
    range: {
        from: number;
        to: number;
    } | {
        last: '15m' | '1h' | '1d' | '1w' | 'run';
    };
    q?: string;
    filters?: Filters;
    live?: boolean;
    /** time breaks off (they are on unless this says false) */
    collapseGaps?: boolean;
    /** the rows with nothing in the range shown (they are hidden unless this says true) */
    quietRows?: boolean;
}
/** A recorded history in one file: a fixture, or an export. */
export interface Recording<T extends TimelineTypes = AnyTimeline> {
    timeline: 1;
    type: 'recording';
    catalog: Catalog<T>;
    events: TimelineEvent<T>[];
    metrics: (MetricPoint | MetricRollup)[];
}
/** What a host gives the timeline component. A fixture source reads a Recording; a simulation is one more source. */
export interface TimelineSource<T extends TimelineTypes = AnyTimeline> {
    catalog(): Promise<Catalog<T>>;
    query(q: Query<T>): Promise<Result<T>>;
    /** live: batches for this query as they happen; returns unsubscribe (on the wire: SSE, §8) */
    subscribe?(q: Query<T>, onBatch: (b: Batch<T>) => void): () => void;
    /** the state recorded at t, where one was (a frame): a canvas follows the playhead */
    stateAt?(scope: Scope, t: number): Promise<T['state'] | undefined>;
}
/** What the generic code needs to know of a domain's timeline. */
export interface TimelineCatalog {
    /** its scope kinds, and what each may sit in ('' is the fleet) */
    kinds: readonly string[];
    parents: Readonly<Record<string, readonly string[]>>;
    /** the flags a scope's name may carry, copied to its row; a flagged row is labelled by its first flag, not its kind */
    flags: readonly string[];
    /** the search's link fields (name:value), in the order the language lists them */
    links: readonly string[];
    /** a link the domain matches its own way as well (a link's value also found in an event's scope); undefined: only
     *  equal ids match */
    linkMatch?(link: string, value: string, e: TimelineEvent): boolean | undefined;
    /** a scope: search value starting with one of these kinds is anchored at the top (else it is segments anywhere) */
    topKinds: readonly string[];
}
/** the pattern a scope path of this catalogue's kinds matches */
export declare const scopePattern: (cat: Pick<TimelineCatalog, 'kinds'>) => string;
