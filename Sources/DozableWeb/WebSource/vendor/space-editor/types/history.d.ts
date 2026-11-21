import type { Bin, MetricPoint, MetricRollup, Query, Result, Row, Scope, TimelineEvent, TimelineSource, View } from './timeline-types.js';
import type { SpaceState } from './state-types.js';
import { type Gap, type TimeScale } from './timeline-scale.js';
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
type Mode = {
    kind: 'single';
} | {
    kind: 'binned';
    bin: Bin;
};
type Line = {
    kind: 'row';
    row: Row;
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
export declare function activityOf(r: Result, mode: Mode, series?: Map<string, 'counter' | 'gauge'>): [number, number][];
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
    /** for tests and hosts: what is drawn, and the mapping */
    internal: {
        readonly result: Result | undefined;
        readonly mode: Mode;
        readonly scale: TimeScale;
        readonly gaps: Gap[];
        readonly playState: SpaceState | undefined;
        readonly hits: TimelineEvent[];
        readonly selected: TimelineEvent | undefined;
        readonly follow: boolean;
        openCut: (from: number, to: number) => void;
        showTable: (from: number, to: number) => Promise<void>;
        rangeEvents: () => Promise<TimelineEvent[]>;
        exportRange: (kind: 'json' | 'csv') => Promise<void>;
        select: (e: TimelineEvent | undefined) => void;
        stepHit: (dir: 1 | -1) => void;
        drill: (s: Scope) => void;
        findHits: () => Promise<void>;
        paint: () => void;
        lines: () => Line[];
    };
    dispose(): void;
};
export type TimelineHandle = ReturnType<typeof mountTimeline>;
export type { MetricPoint, MetricRollup, Row, Query, Result };
