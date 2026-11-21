import type { TimelineEvent } from './timeline-types.js';
/** sensitive: "source.attr" names to leave out */
export declare function toJSON(events: TimelineEvent[], sensitive?: Iterable<string>): string;
/** CSV: the base columns, then attr.* and link.* columns for every key present (spreadsheet formulas defused) */
export declare function toCSV(events: TimelineEvent[], sensitive?: Iterable<string>): string;
