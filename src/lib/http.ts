export const USER_AGENT = "Mozilla/5.0 (compatible; Openfeed/0.1; +https://github.com/gautham-v/openfeed)";

export async function fetchWithTimeout(
  url: string,
  ms: number,
  init: RequestInit = {},
): Promise<Response> {
  const ctrl = new AbortController();
  const timer = setTimeout(() => ctrl.abort(), ms);
  try {
    return await fetch(url, {
      redirect: "follow",
      ...init,
      headers: { "User-Agent": USER_AGENT, ...(init.headers ?? {}) },
      signal: ctrl.signal,
      cache: "no-store",
    });
  } finally {
    clearTimeout(timer);
  }
}

export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

export function json(data: unknown, init: ResponseInit = {}): Response {
  return Response.json(data, {
    ...init,
    headers: { "Cache-Control": "no-store", ...(init.headers ?? {}) },
  });
}

export function errorJson(message: string, status = 500): Response {
  return json({ error: message }, { status });
}

export function errMsg(e: unknown): string {
  if (e instanceof Error) return e.name === "AbortError" ? "Timed out" : e.message;
  return String(e);
}
