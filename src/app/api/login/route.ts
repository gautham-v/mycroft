import { NextResponse } from "next/server";
import { AUTH_COOKIE, passwordToken } from "@/lib/auth";

export async function POST(req: Request) {
  const password = process.env.APP_PASSWORD;
  const url = new URL(req.url);
  if (!password) return NextResponse.redirect(new URL("/", url), 303);
  let given = "";
  const ct = req.headers.get("content-type") ?? "";
  if (ct.includes("application/json")) {
    given = String(((await req.json().catch(() => ({}))) as { password?: string }).password ?? "");
  } else {
    given = String((await req.formData().catch(() => null))?.get("password") ?? "");
  }
  if (given !== password) return NextResponse.redirect(new URL("/?e=1", url), 303);
  const res = NextResponse.redirect(new URL("/", url), 303);
  res.cookies.set(AUTH_COOKIE, await passwordToken(password), {
    httpOnly: true,
    secure: url.protocol === "https:",
    sameSite: "lax",
    path: "/",
    maxAge: 60 * 60 * 24 * 365,
  });
  return res;
}
