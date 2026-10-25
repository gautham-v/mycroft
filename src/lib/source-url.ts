/**
 * Normalize what a user typed into "Add source" into an absolute http(s) URL.
 * Pure and dependency-free so the client dialog can share it with the API.
 * Throws an Error with a user-facing message when the input can't be a site URL.
 */
export function normalizeSourceUrl(input: string): string {
  let s = input.trim();
  if (!s) throw new Error("url is required");
  if (s.startsWith("//")) s = s.slice(2);
  const scheme = s.match(/^([a-z][a-z\d+.-]*):\/\//i)?.[1]?.toLowerCase();
  if (scheme && scheme !== "http" && scheme !== "https") throw new Error("Invalid URL: only http and https are supported");
  if (!scheme) s = `https://${s}`;
  let u: URL;
  try {
    u = new URL(s);
  } catch {
    throw new Error("Invalid URL");
  }
  const host = u.hostname;
  const ok = host === "localhost" || host.startsWith("[") || (host.includes(".") && !host.startsWith(".") && !host.includes(".."));
  if (!ok) throw new Error("Invalid URL");
  return u.toString();
}

/** The same URL with `www.` added to or removed from the host, or null when that makes no sense (IPs, localhost). */
export function wwwAlternate(url: string): string | null {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return null;
  }
  const host = u.hostname;
  if (host === "localhost" || host.startsWith("[") || /^\d+(\.\d+){3}$/.test(host)) return null;
  if (host.startsWith("www.")) {
    const bare = host.slice(4);
    if (!bare.includes(".")) return null;
    u.hostname = bare;
  } else {
    u.hostname = `www.${host}`;
  }
  return u.toString();
}
