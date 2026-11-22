// The portable space editor's API, as types: mount(el, options) and what it takes and returns. See INTEGRATION.md.
// Made by the build from the editor's own sources; SpaceState's JSON Schema is space-state-1.schema.json beside it.

/** Put the whole editor inside el (under one <div class="space-editor">); dispose() removes it all. */
export declare function mount(el: HTMLElement, opts?: MountOptions): SpaceEditor;

// ---------- mount's options and handle ----------
export type Theme = 'light' | 'dark' | 'system';
export interface MountOptions {
    /** the file's text */
    text?: string;
    /** the file's name, to tell its problems from those in files it extends (default: the plan's specPath) */
    fileName?: string;
    /** save the text: { ok: true }, or { conflict: true } when it changed elsewhere since it was loaded. None: no Save. */
    onSave?(text: string): Promise<SaveResult>;
    /** the plan of the text: problems, steps, risks. None (or a plan of undefined): the editor's own reader checks the
     *  text, without extends:. */
    plan?(text: string): Promise<SpacePlan | undefined>;
    readOnly?: boolean;
    /** O2: what is true now (a SpaceState, src/doz-space/state-types.ts), asked while Live is on: every 3 s while the
     *  page is visible, every 30 s while it's hidden. Undefined: not known. */
    state?(text: string): Promise<SpaceState | undefined>;
    /** or pushed: called with each new SpaceState while Live is on; returns a function that stops */
    subscribe?(onState: (s: SpaceState) => void): () => void;
    /** O4: the space's runs, and one run in full (its frames and archive), for the runs strip under the canvas (Live) */
    runs?(text: string): Promise<RunSummary[]>;
    run?(text: string, id: string): Promise<RunDetail | undefined>;
    /** O3: answer an open Ask (the Ask flow itself): { ok: true }, or { refused: why } (expired, answered, not an answerer) */
    answer?(askId: string, reply: string): Promise<{
        ok: true;
    } | {
        refused: string;
    }>;
    /** O3: open a room in the host's chat (an Ask's "Open in chat") */
    openChat?(room: string): void;
    /** O8: offer Simulation beside Live (S toggles it): made-up states from the editor's own simulator, drawn exactly as
     *  Live draws real ones and marked "Simulation" on screen; scripted scenes or a seeded random walk over the file's
     *  things, and events injected on demand. Answering an Ask there answers the simulator. Default false. */
    simulate?: boolean;
    /** M1: the Ask cards' motion, as the host's defaults: on or off (default: off under prefers-reduced-motion, else on),
     *  how a card appears and goes, and what it does while showing. The viewer's own choice (the Motion toggle, M, and its
     *  menu) is remembered in storage and wins. Off: nothing on the state layer moves, and an Ask opens with no
     *  transition. Default { appear: 'inflate', idle: 'breathe' }. */
    motion?: {
        enabled?: boolean;
        appear?: 'scale' | 'spin' | 'dissolve' | 'inflate';
        idle?: 'none' | 'jiggle' | 'pirouette' | 'glow' | 'breathe';
    };
    /** M1: offer the Motion menu (the effects to choose from). false: the Motion toggle only. Default true. */
    motionMenu?: boolean;
    /** light, dark, or system (the host's preference, followed live). Default system. */
    theme?: Theme;
    /** called when the text becomes changed-and-unsaved, or saved */
    onDirtyChange?(dirty: boolean): void;
    /** where preferences are kept (panel sizes, the view, the canvas's navigation). None: for this mount only. */
    storage?: {
        get(key: string): string | null;
        set(key: string, value: string | null): void;
    };
    /** v0.4.1: a watch view: the canvas, with Live on, whatever storage says; neither is written to storage (the viewer's
     *  own choice of view and Live stays as it was). Other preferences are read and kept as usual. Default false. */
    watch?: boolean;
    /** the standalone page's own additions (its files and File menu): not for other hosts */
    host?: HostHooks;
}
/** What the standalone page (src/doz-space/entries/main.ts) adds around the editor. */
export interface HostHooks {
    /** the title bar's start (the File menu, the file's name) */
    titleStart?: HTMLElement[];
    /** more sidebar tabs (Files) */
    sideTabs?: {
        id: string;
        label: string;
        icon: string;
        panel: HTMLElement;
    }[];
    /** keys of its own, while the focus is in the editor (⌘O, ⇧⌘S); true: handled */
    keys?(e: KeyboardEvent): boolean;
    keymap?: [string, string][];
    /** the theme and density switches in the title bar */
    themeControls?: boolean;
    /** extends: files, for the properties panel's inherited values (the standalone server resolves them) */
    defaults?(text: string): Promise<{
        name: string;
        text: string;
    }[]>;
    /** go to definition on an extends: file */
    onOpen?(rel: string): void;
    onSaveAs?(): void;
    /** a save conflict the host shows itself (instead of "Changed elsewhere") */
    onConflict?(): void;
    /** the "doz space editor" mark in the title bar */
    brand?: boolean;
}
export interface SpaceEditor {
    getText(): string;
    /** replace the text (a new file, or the host's fresh copy): undo starts again, and it is not dirty */
    setText(text: string): void;
    setReadOnly(readOnly: boolean): void;
    setTheme(theme: Theme): void;
    /** v0.4.1: load and attach features to the mounted editor ('text', 'plan'), keeping the file, its undo history and
     *  the selection. A feature already here does nothing. An unknown name rejects, and so does one that can only come
     *  with a mount ('canvas', 'edit', 'live', 'motion', 'sim', 'timeline'), unless it is already here. */
    addFeatures(names: readonly string[]): Promise<void>;
    /** v0.4.2: fit the drawing to the canvas, as on mount and as the Fit button does, and give the view back to the
     *  editor: until the person next zooms or pans, it stays fitted as the canvas's size changes. For a host whose own
     *  layout settles after mount. Without the canvas feature, nothing. */
    fit(): void;
    dispose(): void;
}

// ---------- the plan (plan(text)) ----------
export interface SpacePlan {
    space: string;
    title: string;
    specPath?: string;
    specSHA: string;
    sources: {
        path: string;
        kind: 'space' | 'defaults' | 'override' | 'env';
        sha256: string;
    }[];
    /** false: no daemon was asked, so facts only it knows read "not known" */
    factsKnown: boolean;
    problems: SpaceProblem[];
    steps: PlanStep[];
    summary: string[];
    risks: SpaceRisk[];
    confirm: string[];
    refusals: string[];
    /** set when up would refuse; absent when up could run */
    refusalCode?: string;
    notes: string[];
    sha: string;
}
export interface SpaceProblem {
    severity: 'error' | 'warning';
    /** a JSON pointer into the file the problem is in */
    pointer: string;
    message: string;
    hint?: string;
    /** the file it is in: the open file, or a defaults or override file it inherits from */
    file: string;
    /** 1-based */
    line: number;
}
/** One risky setting and where it comes from, shown as "setting: source". New fields may be added. */
export interface SpaceRisk {
    setting: string;
    source: string;
    [more: string]: unknown;
}
export interface PlanStep {
    n: number;
    /** what the step makes or checks: folder, agent, room, sandbox, member, tokens, trust, check, manual, … (more kinds will
     *  arrive: an unknown kind is shown as text) */
    kind: string;
    subject: string;
    action: 'run' | 'skip' | 'refuse';
    lifetime: 'external' | 'persisted' | 'run';
    text: string;
    why?: string;
    down?: string;
    op?: string;
    worker?: string;
    permissionMode?: string;
}
/** What save returns: saved, or the file changed elsewhere since it was loaded. */
export type SaveResult = {
    ok: true;
} | {
    conflict: true;
};

// ---------- what is true now (state(text), subscribe), and the runs ----------
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
