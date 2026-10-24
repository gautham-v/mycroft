/** Compact relative time: "now", "23m", "3h", "2d", "5w", "2y". */
export function relativeTime(date: Date | string | number, now: Date | number = Date.now()): string {
  const t = new Date(date).getTime();
  if (Number.isNaN(t)) return "";
  const s = Math.max(0, Math.floor((new Date(now).getTime() - t) / 1000));
  if (s < 60) return "now";
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m`;
  const h = Math.floor(m / 60);
  if (h < 24) return `${h}h`;
  const d = Math.floor(h / 24);
  if (d < 7) return `${d}d`;
  if (d < 365) return `${Math.floor(d / 7)}w`;
  return `${Math.floor(d / 365)}y`;
}

export const STALE_MS = 15 * 60 * 1000;

export function isStale(last: Date | string | null | undefined, now: number = Date.now()): boolean {
  if (!last) return true;
  const t = new Date(last).getTime();
  return Number.isNaN(t) || now - t > STALE_MS;
}
