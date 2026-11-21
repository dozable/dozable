// core/space-editor — The space editor's data (web.md, "The space editor's page"): the file, its plan, what is true now,
// the runs and a run's frames, the save over the version read, an Ask's answer and a room to open. No DOM. Live only from
// events — the pictures' staleness marks (hello, changed, host, arrival, an operation's end) and the Asks' — never a timer.
import { api } from './api-4b89ba3d74057e14.js';
import { answerFromDiagram, onAskChange, rememberAttention } from './asks-4f25919bec407904.js';
import { actOrThrow, waitForOp } from './operations-a1c19bd5aa57d920.js';
import { roomHash } from './routes-9e8c2eeae9c6e070.js';
import { isRemote } from './session-32b26efd4b3dc47f.js';
import { onPicturesStale } from './space-pictures-c43275a25d4dc740.js';
import { loadWorkspace } from './workspaces-87ee868db617fbd9.js';

/// `/api/v1/actions` takes a body of at most 16 KiB: a longer file is saved with the command.
const SAVE_CAP = 16 * 1024;
/// How the daemon's end text of a stale save starts (WebActions: the page's conflict).
const CONFLICT = 'the space file changed since you opened it';

/// The file: {text, sha256, file, shownPath, canSave, command}.
export function readSpace(w) { return api('workspace-space', { method: 'POST', json: { workspace: w } }); }

/// This browser may change the file: this Mac's own, and the daemon says so.
export const canChange = (f) => !isRemote() && !!f.canSave;

/// What the editor's mount() is given about workspace `w`, its file `f` as first read. `on`: {saved(), conflict()}.
export function spaceSource(w, f, on = {}) {
  let base = f.sha256;
  const mac = canChange(f);
  const src = {
    get base() { return base; },
    fileName: f.file,
    async plan(text) { return api('workspace-space-plan', { method: 'POST', json: { workspace: w, text } }); },
    subscribe(cb) {
      let stopped = false, inflight = false, again = false, last = null;
      const read = async () => {
        if (stopped) return;
        if (inflight) { again = true; return; }
        inflight = true;
        try {
          do {
            again = false;
            let st = null;
            try { st = await api('workspace-state', { method: 'POST', json: { workspace: w } }); } catch (_) { st = null; }
            if (stopped) return;
            if (st && st.sha !== last) { last = st.sha; if (mac) rememberAttention(st.attention); cb(st); }
          } while (again && !stopped);
        } finally { inflight = false; }
      };
      read();
      const offs = [onPicturesStale(read), onAskChange(read)];
      return () => { stopped = true; for (const off of offs) off(); };
    },
    async runs() {
      const l = await api('workspace-runs', { method: 'POST', json: { workspace: w } });
      return (l.runs || []).map((r) => ({ id: r.id, startedAt: r.startedAt, ...(r.endedAt ? { endedAt: r.endedAt } : {}),
        frames: r.frames ?? 0, archived: r.archiveStatus === 'written' }));
    },
    async run(_text, id) { return api('workspace-run-frames', { method: 'POST', json: { workspace: w, run: id } }); },
    /// A room the drawing names: the workspace's main room, one of its rooms by its label, else the room in Chat.
    openChat(room) {
      if (!room || room === w) { location.hash = roomHash(w); return; }
      const other = '#/chat/' + encodeURIComponent(room);
      loadWorkspace(w).then((d) => {
        const r = (d.rooms || []).find((x) => x.room === room);
        location.hash = r ? roomHash(w, r.main ? null : r.label) : other;
      }, () => { location.hash = other; });
    },
  };
  if (mac) {
    src.answer = (askId, reply) => answerFromDiagram(askId, reply);
    /// Saved only over the version read; `{conflict: true}` when it changed since — nothing is written then.
    src.onSave = async (text) => {
      const body = { action: 'workspace-space-save', workspace: w, text, ifMatch: base };
      if (new TextEncoder().encode(JSON.stringify(body)).length > SAVE_CAP) {
        throw new Error('Too long to save here: doz workspace edit ' + w + ' --space-file ' + f.shownPath + ' --if-match ' + base);
      }
      const end = await waitForOp(await actOrThrow(body), 120);
      if (!end) throw new Error('No answer yet — Operations shows how it ends.');
      if (end.state !== 'done') {
        if (String(end.text || '').startsWith(CONFLICT)) { if (on.conflict) on.conflict(); return { conflict: true }; }
        throw new Error(end.text || 'It was not saved.');
      }
      // The new version: read again (a later change elsewhere keeps the old base — the next save then conflicts honestly).
      try { const now = await readSpace(w); if (now.text === text) base = now.sha256; } catch (_) { /* the next save says */ }
      if (on.saved) on.saved();
      return { ok: true };
    };
  }
  /// A fresh read (the bar's Reload after a conflict): its text, the new base.
  src.reread = async () => { const now = await readSpace(w); base = now.sha256; return now.text; };
  return src;
}

/// Where the editor keeps a viewer's preferences: this browser's, per workspace.
export function spaceStorage(w) {
  const p = 'doz.space.' + w + '.';
  return {
    get(k) { try { return localStorage.getItem(p + k); } catch (_) { return null; } },
    set(k, v) { try { if (v === null) localStorage.removeItem(p + k); else localStorage.setItem(p + k, v); } catch (_) { /* this page only */ } },
  };
}
