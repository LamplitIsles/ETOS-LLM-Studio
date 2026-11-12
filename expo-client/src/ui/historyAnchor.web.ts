/** Preserve a visible message while a history page and its measured rows arrive. */
export function captureHistoryAnchor(scrollNode: unknown): { restore: () => void; cancel: () => void } | null {
  if (!(scrollNode instanceof HTMLElement)) return null;
  const viewport = scrollNode.getBoundingClientRect();
  const row = [...scrollNode.querySelectorAll<HTMLElement>('[data-testid="message-user"], [data-testid="message-agent"]')].find(element => {
    const bounds = element.getBoundingClientRect();
    return bounds.bottom > viewport.top && bounds.top < viewport.bottom;
  });
  const id = row?.id;
  if (!row || !id) return null;
  const top = row.getBoundingClientRect().top;
  let active = true, started = false, frame = 0;
  const update = () => {
    frame = 0;
    if (!active || !started || !scrollNode.isConnected) return;
    const current = document.getElementById(id);
    if (current && !scrollNode.contains(current)) return;
    if (!current) return;
    const difference = current.getBoundingClientRect().top - top;
    if (Math.abs(difference) > 0.5) scrollNode.scrollTop += difference;
  };
  const schedule = () => { if (active && started && !frame) frame = requestAnimationFrame(update); };
  const observer = new ResizeObserver(schedule);
  if (scrollNode.firstElementChild) observer.observe(scrollNode.firstElementChild);
  scrollNode.addEventListener('scroll', schedule, { passive: true });
  const cancel = () => {
    if (!active) return;
    active = false; observer.disconnect(); if (frame) cancelAnimationFrame(frame);
    scrollNode.removeEventListener('scroll', schedule);
    for (const event of ['pointerdown', 'wheel', 'touchstart', 'keydown']) document.removeEventListener(event, cancel, true);
  };
  for (const event of ['pointerdown', 'wheel', 'touchstart', 'keydown']) document.addEventListener(event, cancel, { capture: true, passive: true });
  return { restore() { started = true; schedule(); }, cancel };
}
