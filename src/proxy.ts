import { NextResponse, type NextRequest } from "next/server";
import { AUTH_COOKIE, passwordToken } from "@/lib/auth";

const LOGIN_HTML = (error: boolean) => `<!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover"><title>Mycroft</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#FAFAF8;color:#1A1A1A;font:15px/1.4 Inter,system-ui,sans-serif}form{display:grid;gap:12px;width:min(320px,90vw)}h1{font-size:20px;margin:0 0 4px}input,button{font:inherit;height:44px;border-radius:8px;border:1px solid #E2E1DC;padding:0 12px;background:#fff}button{background:#0F6E6E;color:#fff;border-color:#0F6E6E}p{color:#9A3A3A;margin:0;font-size:13px}@media(prefers-color-scheme:dark){body{background:#141412;color:#F0EFE9}input{background:#1C1C1A;color:#F0EFE9;border-color:#2E2D29}button{background:#4FB3B3;border-color:#4FB3B3;color:#141412}p{color:#E07068}}</style></head>
<body><form method="post" action="/api/login"><h1>Mycroft</h1>${error ? "<p>Wrong password.</p>" : ""}<input type="password" name="password" placeholder="Password" autofocus autocomplete="current-password"><button type="submit">Unlock</button></form></body></html>`;

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
