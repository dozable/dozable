import { type SpaceState, type ItemState, type ItemType, type Lifetime, type Attention, type AskAttention } from './state-types.js';
/** one thing the file declares, as the simulator walks it */
export interface SimItem {
    subject: string;
    type: Exclude<ItemType, 'member'>;
    lifetime: Lifetime;
    member?: boolean;
}
/** The items of a space/3 file's data (its parsed YAML): agents (with a chat member when they chat or a room lists
 *  them), services, sandboxes, folders and rooms. External when the file says external; persisted when a persist
 *  entry keeps it (a sandbox's disk, a room, a folder); else made for each run. */
export declare function simItemsOf(data: unknown): {
    space: string;
    items: SimItem[];
};
/** a small seeded generator (mulberry32): the same seed, the same run */
export declare function rng(seed: number): {
    next: () => number;
    int: (n: number) => number;
    pick: <T>(xs: readonly T[]) => T | undefined;
};
/** what can be injected (the panel's buttons), and what a random step may do */
export type SimEvent = {
    kind: 'ask';
    agent?: string;
    count?: number;
} | {
    kind: 'answer';
    askId?: string;
} | {
    kind: 'expire';
    askId?: string;
} | {
    kind: 'session';
    to: 'asleep' | 'running' | 'ended';
    agent?: string;
} | {
    kind: 'room';
    to: 'closed' | 'archived' | 'gone' | 'open';
    room?: string;
} | {
    kind: 'problem';
} | {
    kind: 'refusal';
} | {
    kind: 'clear';
} | {
    kind: 'extra';
} | {
    kind: 'run';
    to: 'start' | 'end';
} | {
    kind: 'facts';
    known: boolean;
} | {
    kind: 'service';
    to: 'healthy' | 'unhealthy' | 'starting' | 'stopped';
} | {
    kind: 'unextra';
};
/** Monkey: its intensities, as events a second (real time) and the largest burst */
export declare const MONKEY: {
    readonly 1: {
        readonly perSecond: 2;
        readonly burst: 2;
    };
    readonly 2: {
        readonly perSecond: 4;
        readonly burst: 3;
    };
    readonly 5: {
        readonly perSecond: 10;
        readonly burst: 4;
    };
    readonly 10: {
        readonly perSecond: 20;
        readonly burst: 6;
    };
};
export type Intensity = keyof typeof MONKEY;
/** at most this many Asks open at once, however wild (the canvas stays readable and bounded) */
export declare const MAX_ASKS = 12;
export declare const INJECTS: {
    label: string;
    ev: SimEvent;
}[];
interface World {
    clock: number;
    known: boolean;
    everRan: boolean;
    runs: number;
    run?: {
        id: string;
        startedAt: string;
        phase: 'starting' | 'up' | 'stopping';
    };
    /** the state of each item while it exists in reality (keyed type:subject) */
    st: Map<string, {
        state: string;
        activity?: 'working' | 'idle' | 'waiting';
        since: string;
    }>;
    extras: ItemState[];
    asks: AskAttention[];
    other: Attention[];
    nextAsk: number;
    nextExtra: number;
}
/** the time between two events, in ms of simulated time */
export declare const STEP = 15000;
/** one event in the log: when, what (words), its effect on the world, and the state it left */
export interface SimLogEntry {
    at: number;
    label: string;
    kind: string;
    delta: Partial<WorldSnap>;
    state: SpaceState;
    keyframe?: boolean;
}
/** the world as plain data */
interface WorldSnap {
    clock: number;
    known: boolean;
    everRan: boolean;
    runs: number;
    run: World['run'] | null;
    nextAsk: number;
    nextExtra: number;
    st: Record<string, {
        state: string;
        activity?: 'working' | 'idle' | 'waiting';
        since: string;
    }>;
    extras: ItemState[];
    asks: AskAttention[];
    other: Attention[];
}
export interface SimulatorOpts {
    space: string;
    items: SimItem[];
    seed?: number;
    host?: string;
    start?: string;
    answerers?: string[];
}
/** The simulated space: a world, the state it shows, random steps and injected events. */
export declare class Simulator {
    readonly space: string;
    readonly items: SimItem[];
    readonly seed: number;
    private r;
    private w;
    private host;
    private answerers;
    /** every state made (the log's), for the runs strip (each run's frames) */
    get history(): SpaceState[];
    constructor(o: SimulatorOpts);
    /** Take a state as the world (a scripted scene, a recorded fixture): what it says becomes what the simulator
     *  changes from, so an injected event or an answer works on whatever is shown. */
    load(st: SpaceState, label?: string, at?: number): SpaceState;
    private loadNow;
    /** the current state */
    get state(): SpaceState;
    private make;
    /** an Ask stands over a running agent, or an extra */
    private canAsk;
    private record;
    /** the log, in order of time (the first entry is the start) */
    log: SimLogEntry[];
    private w0;
    private depth;
    /** run an event: the outermost one is logged */
    private tx;
    /** the world at a time: the start, and every logged delta at or before it */
    private worldAt;
    /** the state at a time, as the fold of the log up to it (a keyframe's own state when it is the last event): the
     *  definition, which stateAt keeps to (the tests prove the two equal at every event) */
    foldAt(t: number): SpaceState;
    /** the state at a time: the state the last event at or before it left (found by halves: Monkey logs thousands) */
    stateAt(t: number): SpaceState;
    /** the log's end (the last event's time) */
    get end(): number;
    /** drop every event after t (a new branch from there): the world is as it was at t */
    truncate(t: number): boolean;
    /** an event at the clock as it is (an injection at the playhead), not the next step on */
    applyAt(ev: SimEvent, t: number): SpaceState;
    private agents;
    private set;
    /** a thing made for this run, or kept by the space, can only be there while a run is open or once one has run */
    private exists;
    /** Apply one event; returns the new state. An event with nothing to act on changes nothing but the clock. */
    apply(ev: SimEvent): SpaceState;
    private applyNow;
    /** A person answered an Ask on the canvas (answer() in Simulation): it goes on the next state. */
    answer(askId: string): {
        ok: true;
    } | {
        refused: string;
    };
    /** Monkey: one burst of chaos, seeded (the same seed and intensity, the same chaos): up to the intensity's burst of
     *  events, from every kind there is: Asks in bursts, answered and expiring; sessions flapping and crash-looping;
     *  rooms closing, archiving and coming back; services going unhealthy; extras coming and going; problems and
     *  refusals; runs starting and stopping; facts flipping to unknown. Each event is logged; the rules hold throughout. */
    monkey(intensity?: Intensity): SpaceState;
    /** One random step: a plausible transition of the open file's items. */
    step(): SpaceState;
    private lastLabel;
    private stepNow;
    /** the runs so far, for the runs strip: each with the states made while it was open */
    runs(): {
        id: string;
        startedAt: string;
        endedAt?: string;
        frames: SpaceState[];
    }[];
}
/** The scripted scenes, in order (made for any file by the same events a person can inject). */
export declare const SCENES: readonly ['down', 'running', 'asleep', 'attention', 'answered', 'drift', 'down'];
export type Scene = (typeof SCENES)[number];
/** The scenes for a file, as states: each made from the one before by a few events. */
export declare function scriptedScenes(o: SimulatorOpts): {
    scene: Scene;
    state: SpaceState;
}[];
export {};
