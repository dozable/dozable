// components/chat-tables — a table wider than its bubble scrolls sideways; a soft shade on an edge says there is more.
const edges = (t) => {
  const w = t.parentNode;
  if (!w || !w.classList || !w.classList.contains('chat-tw')) return;
  w.classList.toggle('is-more-left', t.scrollLeft > 1);
  w.classList.toggle('is-more-right', t.scrollLeft + t.clientWidth < t.scrollWidth - 1);
};
const ro = window.ResizeObserver ? new ResizeObserver((es) => es.forEach((e) => edges(e.target))) : null;
export function watchTables(root) {
  root.querySelectorAll('.chat-tw > table').forEach((t) => {
    t.addEventListener('scroll', () => edges(t), { passive: true });
    if (ro) ro.observe(t);
    edges(t);
  });
}
