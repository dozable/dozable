import type { SpaceState } from './state-types.js';
import type * as C from './timeline-contract.js';
import { type TimelineCatalog } from './timeline-contract.js';
export { TIMELINE_VERSION, SEGMENT_NAME, SEVERITIES, BINS, BIN_MS } from './timeline-contract.js';
export type { Scope, Severity, AttrValue, Bin, MetricPoint, MetricRollup, EventBin, Days, Retention, KindInfo, EffectiveRetention, Filters, View } from './timeline-contract.js';
/** A scope's segments, outermost first. A path is "kind:name" segments joined by "/", e.g.
 *  host:host-a/workspace:example-space/sandbox:build-vm/session:agent~812. The fleet is the empty path "". A space is a
 *  workspace (its row says space: true). */
export declare const SCOPE_KINDS: readonly ['host', 'workspace', 'sandbox', 'session', 'room', 'run'];
export type ScopeKind = typeof SCOPE_KINDS[number];
/** what each kind may sit in ('' is the fleet). A sandbox, a session or a room whose workspace isn't known (an ended
 *  worker, a removed sandbox, a room in no workspace or several, a session on the Mac) sits straight in its host. */
export declare const SCOPE_PARENTS: Record<ScopeKind, readonly (ScopeKind | '')[]>;
export declare const SCOPE_PATTERN: string;
export interface EventLinks {
    /** a run, qualified by its workspace: "example-space/2026-11-20-1" (a run's id is unique only within its workspace) */
    run?: string;
    /** a chat Ask's number, "#12" */
    ask?: string;
    /** a chat message's id: never its text */
    msg?: string;
    /** a session's row id (its name is reused; the scope carries name~rowid) */
    session?: string;
    /** a grants-log line's id */
    decision?: string;
}
/** doz's timeline: its kinds, its frames, the space flag, its links */
export interface Doz extends C.TimelineTypes {
    kind: ScopeKind;
    state: SpaceState;
    flag: 'space';
    links: EventLinks;
}
export type TimelineEvent = C.TimelineEvent<Doz>;
export type Match = C.Match<Doz>;
export type AstTerm = C.AstTerm<Doz>;
export type SearchAst = C.SearchAst<Doz>;
export type SeriesInfo = C.SeriesInfo<Doz>;
export type SourceInfo = C.SourceInfo<Doz>;
/** A scope's display: its label (a room's name, for a room scoped by its id), whether a workspace is a space, and the
 *  scopes it was known as before a rename (their history shows on its row). */
export type ScopeName = C.ScopeName<Doz>;
export type Catalog = C.Catalog<Doz>;
export type Query = C.Query<Doz>;
/** A row: one scope at the query's depth; space: a workspace made from a space file. */
export type Row = C.Row<Doz>;
export type Result = C.Result<Doz>;
export type Batch = C.Batch<Doz>;
export type Recording = C.Recording<Doz>;
/** What a host gives the timeline component. A fixture source reads a Recording; Simulation is one more source. Its
 *  stateAt: the space's state at t, where one was recorded (a run frame): the canvas follows the playhead. Never an
 *  Ask's question. */
export type TimelineSource = C.TimelineSource<Doz>;
/** what the generic timeline is told of doz's: the kinds and their nesting, the space flag (a space's row is labelled
 *  "space"), the search's links, a run link also matching any scope in that run, and host: scopes anchored at the top */
export declare const DOZ_TIMELINE: TimelineCatalog;
/** the workspace log's own action names that the contract knows of (any other is workspace.<action>, verbatim) */
export declare const WORKSPACE_ACTIONS: string[];
/** chat message states, one event per recipient */
export declare const MESSAGE_STATES: string[];
export declare const SOURCES: SourceInfo[];
/** the attrs no source may ever carry: text, secrets, argv, and the parts of a request beyond its host and port */
export declare const NEVER_ATTRS: string[];
/** how the viewer's own name is written in a people attr */
export declare const YOU = "you";
