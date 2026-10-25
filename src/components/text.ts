export function stripHtml(html: string | null | undefined): string {
  if (!html) return "";
  return html
    .replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;|&#x27;/g, "'")
    .replace(/\s+/g, " ")
    .trim();
}

export function readMinutes(text: string): number {
  const words = text.split(/\s+/).filter(Boolean).length;
  return Math.max(1, Math.round(words / 230));
}

export function formatDuration(sec: number | null): string | null {
  if (!sec || sec <= 0) return null;
  const h = Math.floor(sec / 3600);
  const m = Math.floor((sec % 3600) / 60);
  const s = sec % 60;
  const ss = String(s).padStart(2, "0");
  return h ? `${h}:${String(m).padStart(2, "0")}:${ss}` : `${m}:${ss}`;
}

export function formatDate(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });
}

export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

const X_POST = /^https?:\/\/(?:www\.|mobile\.)?(?:twitter|x)\.com\/[^/]+\/status\/\d+/i;
/** A post on X: the reader shows it as a post (no headline), the list leads with the author. */
export const isXPost = (url: string) => X_POST.test(url);

/** "Kun Chen (@kunchenguid)" → name and handle. */
export function splitHandle(author: string | null): { name: string; handle: string | null } {
  const m = /^(.*?)\s*\(@([A-Za-z0-9_]+)\)\s*$/.exec(author ?? "");
  return m ? { name: m[1], handle: m[2] } : { name: author ?? "", handle: null };
}
