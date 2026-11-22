import { type MetricPoint, type MetricRollup, type Recording, type Retention, type Scope, type TimelineEvent, type TimelineSource, type TimelineCatalog } from './timeline-contract.js';
export interface MemorySourceOptions {
    /** the host's now (default: the recording's catalog.now) */
    now?: number;
    /** the state at t, where one was recorded (frames), as the timeline may show it */
    stateAt?(scope: Scope, t: number): Promise<unknown>;
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
export declare function memorySource(rec: Recording, cat: TimelineCatalog, o?: MemorySourceOptions): MemorySource;
