// core/ws-log — A workspace's log as a room shows it (pure: no DOM, no state). The lines come from GET
// /api/v1/workspaces/{w}/log — the CLI's sentences (`doz workspace log`), never posted in the room: the page draws them
// among the messages by time, as `doz chat read ROOM --with-log` prints them.

/// A line's time in seconds (the answer's ISO 8601 time; a message's `at` is seconds already).
export function lineAt(line) {
  const t = Date.parse(line && line.at);
  return Number.isFinite(t) ? t / 1000 : 0;
}

/// The lines a room shows: one naming a room only there, the rest in the workspace's main room.
export function forRoom(lines, room, mainRoom) {
  return (lines || []).filter((l) => (l.room ? l.room === room : room === mainRoom));
}

/// Messages (each {at}, in order) and log lines merged by time: [{kind: 'msg' | 'line', item}]. A line comes before a
/// message of the same time. Only the lines from the first message's time on — the span loaded — unless `all` (the room
/// holds nothing older), and every line when there is no message.
export function interleave(messages, lines, all) {
  const ms = messages || [];
  const from = all || !ms.length ? -Infinity : +ms[0].at || 0;
  const ls = (lines || []).filter((l) => lineAt(l) >= from).slice().sort((a, b) => lineAt(a) - lineAt(b));
  const out = [];
  let i = 0;
  for (const m of ms) {
    const at = +m.at || 0;
    while (i < ls.length && lineAt(ls[i]) <= at) out.push({ kind: 'line', item: ls[i++] });
    out.push({ kind: 'msg', item: m });
  }
  while (i < ls.length) out.push({ kind: 'line', item: ls[i++] });
  return out;
}

/// A line as a person reads it: who (you by your chat name; Dozable for what it did itself), then the CLI's sentence.
export function lineText(line, you) {
  return (line.by === 'you' ? (you || 'You') : 'Dozable') + ' ' + String(line.text || '');
}

/// One key per line (the same line read twice — a `since` read repeats the last — is drawn once).
export function lineKey(line) {
  return [line.at, line.action, line.room || '', line.agent || '', line.text].join('|');
}

/// Lines read again added to those known, in time order, each once.
export function mergeLines(known, more) {
  const seen = new Set((known || []).map(lineKey));
  const out = (known || []).slice();
  for (const l of more || []) if (!seen.has(lineKey(l))) { seen.add(lineKey(l)); out.push(l); }
  return out.sort((a, b) => lineAt(a) - lineAt(b));
}

/// The brief's edits, newest first: {at, bytes, announced} — `announced` when the log says the edit was posted in a room
/// (an edit after the start). Older texts are not kept: each announcement carries the text.
export function briefEdits(lines) {
  const ls = lines || [];
  const out = [];
  for (let i = 0; i < ls.length; i++) {
    const l = ls[i];
    if (l.action !== 'brief-edited') continue;
    const m = /\((\d+) bytes\)/.exec(String(l.text || ''));
    const next = ls.slice(i + 1).find((x) => x.action === 'brief-announced' || x.action === 'brief-edited');
    out.push({ at: l.at, bytes: m ? +m[1] : null, announced: !!next && next.action === 'brief-announced' && lineAt(next) - lineAt(l) < 60, line: l });
  }
  return out.reverse();
}
