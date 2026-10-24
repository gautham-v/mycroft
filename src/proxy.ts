import { NextResponse, type NextRequest } from "next/server";
import { AUTH_COOKIE, passwordToken } from "@/lib/auth";

const LOGIN_HTML = (error: boolean) => `<!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>Openfeed</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#F2F2F4;color:#1D1D1F;font:15px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","Helvetica Neue",Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}form{display:grid;gap:12px;width:min(320px,90vw)}h1{font-size:20px;font-weight:700;letter-spacing:-.02em;margin:0 0 4px}input,button{font:inherit;height:44px;border-radius:8px;border:1px solid #D2D2D7;padding:0 12px;background:#fff;color:inherit}button{background:#007AFF;color:#fff;border-color:#007AFF;font-weight:500}p{color:#FF3B30;margin:0;font-size:13px}@media(prefers-color-scheme:dark){body{background:#000;color:#F5F5F7}input{background:#161618;border-color:#2C2C2E}button{background:#0A84FF;border-color:#0A84FF;color:#fff}p{color:#FF453A}}</style></head>
<body><form method="post" action="/api/login"><h1>Openfeed</h1>${error ? "<p>Wrong password.</p>" : ""}<input type="password" name="password" placeholder="Password" autofocus autocomplete="current-password"><button type="submit">Unlock</button></form></body></html>`;

export async function proxy(req: NextRequest) {
  const password = process.env.APP_PASSWORD;
  if (!password) return NextResponse.next();

  const { pathname } = req.nextUrl;
  if (pathname === "/api/login") return NextResponse.next();

  const secret = process.env.CRON_SECRET;
  const cronOk =
    (secret && req.headers.get("authorization") === `Bearer ${secret}`) ||
    (!secret && req.headers.get("x-vercel-cron") !== null);
  if (pathname === "/api/refresh" && cronOk) {
    return NextResponse.next();
  }

  const token = req.cookies.get(AUTH_COOKIE)?.value;
  if (token && token === (await passwordToken(password))) return NextResponse.next();

  if (pathname.startsWith("/api/")) {
    return NextResponse.json({ error: "Unauthorized" }, { status: 401, headers: { "Cache-Control": "no-store" } });
  }
  return new NextResponse(LOGIN_HTML(req.nextUrl.searchParams.has("e")), {
    status: 401,
    headers: { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  });
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|manifest.webmanifest|sw.js|icons/|apple-touch-icon).*)",
  ],
};
