import { type Recording, type Scope } from './timeline-types.js';
import type { SpaceState } from './state-types.js';
import { type MemorySource } from './timeline.js';
import { type Simulator } from './simulator.js';
export declare const HOST = "host:host-a";
export declare const SPACE = "host:host-a/workspace:example-space";
export declare const DOCS = "host:host-a/workspace:docs-site";
/** docs-site's name before it was renamed, midweek */
export declare const DOCS_BEFORE = "host:host-a/workspace:docs";
/** a sandbox removed early in the week: its workspace isn't known any more, so it sits straight in the host */
export declare const OLD_VM = "host:host-a/sandbox:old-vm";
/** the workspaces, their sandboxes (and a session placed on the host), agents, and the programs sessions run */
export declare const LAYOUT: readonly [{
    readonly ws: "host:host-a/workspace:example-space";
    readonly sandboxes: readonly ['build-vm', 'test-vm'];
    readonly agents: readonly ['worker', 'helper'];
    readonly space: true;
    readonly hostSession: false;
}, {
    readonly ws: "host:host-a/workspace:docs-site";
    readonly sandboxes: readonly ['docs-vm'];
    readonly agents: readonly ['writer'];
    readonly space: false;
    readonly hostSession: true;
}];
export interface RunFrame {
    run: string;
    scope: Scope;
    t: number;
    state: SpaceState;
}
export interface Week {
    recording: Recording;
    frames: RunFrame[];
}
/** the week [start, start + days), its now at the end */
export declare function recordedWeek(o?: {
    seed?: number;
    start?: number;
    days?: number;
    frame?: (run: string, t: number, phase: 'up' | 'down', i: number) => SpaceState;
}): Week;
/** the frame at or before t in the run whose scope holds `scope` (or any run, for a workspace's scope), within that run */
export declare function frameAt(frames: RunFrame[], scope: Scope, t: number): RunFrame | undefined;
/** A recording, and its frames, as a source: the canvas follows the playhead where a frame was recorded. */
export declare function fixtureSource(rec: Recording, frames?: RunFrame[], now?: number): MemorySource;
/** More of the week, as it happens: actions, chat and decisions at now, network minutes as each minute turns (and the
 *  minute before grown, as a host's late counters do). rate: events per second on average (Monkey's 10×: 20). */
export declare function liveFeed(src: MemorySource, o?: {
    rate?: number;
    seed?: number;
    tick?: number;
    clock?: () => number;
    schedule?: (f: () => void, ms: number) => unknown;
    cancel?: (h: unknown) => void;
}): {
    stop: () => void;
    step: () => void;
};
/** Simulation's event log as a source (one more source): each logged event a mark on the space's row, its states for
 *  stateAt. Call refresh() after the simulator moves. */
export declare function simulationSource(sim: Simulator, scope?: Scope): MemorySource & {
    /** what the simulator logged since, appended; false after a branch (the log was cut): make a new source */
    refresh(): boolean;
};
