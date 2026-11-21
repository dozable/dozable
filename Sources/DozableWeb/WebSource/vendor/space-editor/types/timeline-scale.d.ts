export interface Gap {
    from: number;
    to: number;
}
export interface Cut extends Gap {
    x0: number;
    x1: number;
    weight: number;
}
/** The gaps of [t0, t1): activity intervals are [a, b) (a mark is [t, t]); a gap is a stretch between them (or between
 *  the range's edges and them) longer than minFrac of the range and than minMs. */
export declare function findGaps(activity: [number, number][], t0: number, t1: number, o?: {
    minFrac?: number;
    minMs?: number;
}): Gap[];
/** "14 h", "2 d 3 h", "45 min" */
export declare function gapLabel(ms: number): string;
export interface TimeScale {
    t0: number;
    t1: number;
    width: number;
    cuts: Cut[];
    x(t: number): number;
    /** the time at x; inside a cut, its nearer edge */
    t(x: number): number;
    /** the cut at x, if any */
    cutAt(x: number): Cut | undefined;
    /** visible ms per px outside the cuts */
    msPerPx: number;
}
/** weights: how far each gap is expanded (0: a cut; 1: its own width in time), by gapKey */
export declare const gapKey: (g: Gap) => string;
export declare function timeScale(t0: number, t1: number, width: number, gaps?: Gap[], o?: {
    cut?: number;
    weights?: Map<string, number>;
}): TimeScale;
export interface Tick {
    t: number;
    x: number;
    label: string;
    major: boolean;
}
/** round times at least minPx apart, in the owner's zone (local hours and days), skipping the cuts */
export declare function ticks(s: TimeScale, tz?: string, minPx?: number): Tick[];
