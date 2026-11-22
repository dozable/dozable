import type { TimelineEvent, TimelineTypes, AnyTimeline } from './timeline-contract.js';
/** sensitive: "source.attr" names to leave out */
export declare function toJSON<T extends TimelineTypes = AnyTimeline>(events: TimelineEvent<T>[], sensitive?: Iterable<string>): string;
/** CSV: the base columns, then attr.* and link.* columns for every key present (spreadsheet formulas defused) */
export declare function toCSV<T extends TimelineTypes = AnyTimeline>(events: TimelineEvent<T>[], sensitive?: Iterable<string>): string;
