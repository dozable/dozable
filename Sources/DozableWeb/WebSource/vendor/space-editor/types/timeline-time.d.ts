import type { Bin } from './timeline-types.js';
/** the zone's offset from UTC at t, in ms (UTC, or an unknown zone: 0) */
export declare function offsetAt(tz: string | undefined, t: number): number;
export declare const isZone: (tz: string) => boolean;
/** the start of the bin t falls in */
export declare function binStart(t: number, bin: Bin, tz?: string): number;
/** the start of the next bin after a bin starting at s */
export declare function binNext(s: number, tz?: string, bin?: Bin): number;
