import type { Bin, MetricPoint, MetricRollup, Query, Result, Row, Scope, TimelineEvent, TimelineSource, View, TimelineCatalog, TimelineTypes, AnyTimeline } from './timeline-contract.js';
import { type Gap, type TimeScale } from './timeline-scale.js';
export interface TimelineMountOptions<T extends TimelineTypes = AnyTimeline> {
    source: TimelineSource<T>;
    /** the domain's scopes, flags and search links */
    catalog: TimelineCatalog;
    /** classes on the component's root beside its own (the stylesheet it is styled by is scoped to one) */
    rootClass?: string[];
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
    /** an event's actions, in its detail: a label, and what it does (none: not shown) */
    actions?(e: TimelineEvent<T>): [string, (() => void) | undefined][];
    /** saved views: the host stores them */
    saveView?(v: View): void | Promise<void>;
    views?(): View[] | Promise<View[]>;
    /** the playhead moved: the state recorded there, if any (draw it on a canvas) */
    onPlayhead?(t: number, state: T['state'] | undefined): void;
    /** a recorded state, in words for the canvas's note: when it was observed, and what it belongs to */
    stamp?(state: T['state']): {
        at?: string;
        tag?: string;
    };
    onViewChange?(v: View): void;
    /** an export: the host saves it (else the browser downloads it) */
    onExport?(name: string, text: string, type: string): void;
}
type Mode = {
    kind: 'single';
} | {
    kind: 'binned';
    bin: Bin;
};
type Line<T extends TimelineTypes = AnyTimeline> = {
    kind: 'row';
    row: Row<T>;
} | {
    kind: 'metric';
    series: string;
    unit: string;
    type: 'counter' | 'gauge';
    title: string;
};
/** which zoom level a visible span reads at: single events up to a few hours, then minute, hour and day bins */
export declare function modeFor(span: number, px: number): Mode;
/** the activity a result shows (for time breaks): marks, span ends, bins with events, metrics that moved */
export declare function activityOf<T extends TimelineTypes = AnyTimeline>(r: Result<T>, mode: Mode, series?: Map<string, 'counter' | 'gauge'>): [number, number][];
export declare function mountTimeline<T extends TimelineTypes = AnyTimeline>(el: HTMLElement, o: TimelineMountOptions<T>): {
    el: HTMLElement;
    ready: Promise<void>;
    readonly view: View;
    setView(v: Partial<View>): Promise<void>;
    setRange(t0: number, t1: number): Promise<void>;
    setPlayhead: (t: number | undefined) => Promise<void>;
    setLive: (on: boolean, go?: boolean) => void;
    setTheme: (t?: 'light' | 'dark' | 'system') => void;
    refresh: () => Promise<void>;
    /** for tests and hosts: what is drawn, and the mapping */
    internal: {
        readonly result: Result<T> | undefined;
        readonly mode: Mode;
        readonly scale: TimeScale;
        readonly gaps: Gap[];
        readonly playState: T["state"] | undefined;
        readonly hits: TimelineEvent<T>[];
        readonly selected: TimelineEvent<T> | undefined;
        readonly follow: boolean;
        openCut: (from: number, to: number) => void;
        showTable: (from: number, to: number) => Promise<void>;
        rangeEvents: () => Promise<TimelineEvent<T>[]>;
        exportRange: (kind: 'json' | 'csv') => Promise<void>;
        select: (e: TimelineEvent<T> | undefined) => void;
        stepHit: (dir: 1 | -1) => void;
        drill: (s: Scope) => void;
        findHits: () => Promise<void>;
        paint: () => void;
        lines: () => Line<T>[];
    };
    dispose(): void;
};
export type TimelineHandle = ReturnType<typeof mountTimeline>;
export type { MetricPoint, MetricRollup, Row, Query, Result };
