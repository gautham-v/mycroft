export const AUTH_COOKIE = "openfeed_auth";

/** Cookie value = sha256(APP_PASSWORD) hex. */
export async function passwordToken(password: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`openfeed:${password}`));
  return Array.from(new Uint8Array(buf), (b) => b.toString(16).padStart(2, "0")).join("");
}
