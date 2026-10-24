import { connection, type NextRequest } from "next/server";
import { refreshAll } from "@/lib/fetcher";
import { errMsg, errorJson, json } from "@/lib/http";

export const maxDuration = 60;

async function handle(req: NextRequest) {
  await connection();
  try {
    const secret = process.env.CRON_SECRET;
    const isCron = !!secret && req.headers.get("authorization") === `Bearer ${secret}`;
    const force = isCron || req.nextUrl.searchParams.get("force") === "1";
    return json(await refreshAll({ force }));
  } catch (e) {
    return errorJson(errMsg(e));
  }
}

export const GET = handle;
export const POST = handle;
