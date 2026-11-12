import type { TimelineRow } from './timelineRows';

const GROUP_INTERVAL_MS = 15 * 60 * 1000;

// Match Lamplit's local chat day, which begins at 04:00 rather than midnight.
function chatDay(value: number): Date | undefined {
  const date = new Date(value);
  if (!Number.isFinite(date.getTime())) return undefined;
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() - (date.getHours() < 4 ? 1 : 0), 12);
}

export function nextChatDayBoundary(now: number): number {
  const date = new Date(now);
  date.setHours(4, 0, 0, 0);
  if (date.getTime() <= now) date.setDate(date.getDate() + 1);
  return date.getTime();
}

export function chatTimeHeadings(rows: readonly TimelineRow[], now: number): Record<string, string> {
  const headings: Record<string, string> = Object.create(null);
  const today = chatDay(now);
  let previous: number | undefined;
  for (const row of rows) {
    if (row.original?.role === 'notice') continue;
    const day = chatDay(row.createdAt);
    if (!day) { previous = undefined; continue; }
    if (previous === undefined || Math.abs(row.createdAt - previous) >= GROUP_INTERVAL_MS) {
      const date = new Date(row.createdAt);
      const time = `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`;
      let prefix = '';
      if (today && day.getTime() !== today.getTime()) {
        const serial = (value: Date) => Date.UTC(value.getFullYear(), value.getMonth(), value.getDate());
        prefix = (serial(today) - serial(day)) / 86_400_000 === 1 ? '昨天' : new Intl.DateTimeFormat('zh-CN', {
          month: 'long', day: 'numeric', ...(day.getFullYear() !== today.getFullYear() ? { year: 'numeric' } : {}),
        }).format(day);
      }
      headings[row._id] = [prefix, time].filter(Boolean).join(' ');
    }
    previous = row.createdAt;
  }
  return headings;
}
