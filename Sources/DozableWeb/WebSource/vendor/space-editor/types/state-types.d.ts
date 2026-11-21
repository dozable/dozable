export declare const STATE_VERSION = 1;
export type ItemType = 'agent' | 'service' | 'sandbox' | 'folder' | 'room' | 'member';
export type Lifetime = 'external' | 'persisted' | 'run';
/** Each type's states. Every type also has "unknown" (not known is an answer: never shown as healthy) and "gone"
 *  (removed by down, as it should be: no drift). */
export declare const STATES: Record<ItemType, readonly string[]>;
export interface ItemState {
    /** the same subject string the plan's steps use (a resource's name; a member's chat name) */
    subject: string;
    type: ItemType;
    lifetime: Lifetime;
    /** one of STATES[type] */
    state: string;
    /** agents only */
    activity?: 'working' | 'idle' | 'waiting' | 'unknown';
    /** one line a person reads: "port 8177, 200 OK", "3 members, last message 2m ago" (never a message's text) */
    detail?: string;
    /** when it entered this state, if known */
    since?: string;
    drift?: {
        kind: 'missing' | 'extra' | 'differs';
        text: string;
    };
}
export type AttentionKind = 'permission' | 'trust' | 'confirm' | 'health' | 'refusal' | 'problem' | 'ask';
export interface Attention {
    subject: string;
    kind: AttentionKind;
    text: string;
    since?: string;
}
/** An open chat Ask (DESIGN.md §4a). question is live only: absent when hidden from this viewer, never in fixtures. */
export interface AskAttention extends Attention {
    kind: 'ask';
    askId: string;
    room: string;
    from: string;
    openedAt: string;
    expiresAt?: string;
    question?: string;
    options: string[];
    answerers: string[];
    canAnswer: boolean;
}
export interface SpaceState {
    version: typeof STATE_VERSION;
    space: string;
    observedAt: string;
    /** false: no daemon reachable; every item then says "unknown" */
    factsKnown: boolean;
    /** a display name only */
    host: string;
    run?: {
        id: string;
        startedAt: string;
        endedAt?: string;
        phase: 'starting' | 'up' | 'stopping' | 'down';
    };
    /** one per thing the file declares */
    items: ItemState[];
    /** present in reality, matching the space's names, not in the file */
    extras: ItemState[];
    attention: (Attention | AskAttention)[];
    /** sha256 of the document without sha and observedAt: the same facts, the same sha */
    sha: string;
}
/** One run of the space: its window, and how much of it was kept. */
export interface RunSummary {
    id: string;
    startedAt: string;
    /** absent while it is open */
    endedAt?: string;
    /** status snapshots kept for it: the frames a replay steps through */
    frames: number;
    /** down archived it (a manifest exists) */
    archived: boolean;
    /** the space's final record, after down --purge */
    retired?: boolean;
}
/** A run in full: its frames in order, and what down kept. Frames carry states and lifetimes, never an Ask. */
export interface RunDetail {
    id: string;
    frames: {
        file: string;
        label: string;
        at: string;
        state: SpaceState;
    }[];
    archive?: {
        /** where it is kept, as the host names it (a path under the home folder is written ~) */
        path: string;
        files: {
            path: string;
            bytes: number;
            sha256: string;
        }[];
        /** every file the manifest lists is there, with the sha256 it lists */
        verified: boolean;
        /** the files that aren't, or differ */
        mismatched: string[];
    };
}
