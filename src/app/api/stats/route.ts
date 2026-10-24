import { connection } from "next/server";
import { getLastRefreshAt } from "@/lib/fetcher";
import { errMsg, errorJson, json } from "@/lib/http";
import type { Stats } from "@/lib/types";

export async function GET() {
  await connection();
  try {
    const body: Stats = { lastRefreshAt: await getLastRefreshAt() };
    return json(body);
  } catch (e) {
    return errorJson(errMsg(e));
  }
}
