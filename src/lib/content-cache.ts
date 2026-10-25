import type { ItemRow } from "@/db/schema";
import type { ContentResponse } from "./types";

/** Response for an item whose extracted copy is already cached. */
export function cachedContent(
  item: Pick<ItemRow, "contentHtml" | "contentRendered">,
  leadImage: string | null,
): ContentResponse {
  return {
    contentHtml: item.contentHtml,
    leadImage,
    ...(item.contentRendered ? { rendered: true } : {}),
  };
}

/** Columns to write after a fresh extraction; null when there's nothing to cache. */
export function contentUpdate(
  out: { contentHtml: string | null; leadImage: string | null; rendered?: boolean },
  storedLead: string | null,
): Partial<Pick<ItemRow, "contentHtml" | "contentRendered" | "thumbnailUrl">> | null {
  if (!out.contentHtml) return null;
  return {
    contentHtml: out.contentHtml,
    // Always written, so a re-extract (?refresh=1) that no longer needs the fallback clears it.
    contentRendered: !!out.rendered,
    ...(storedLead ? {} : { thumbnailUrl: out.leadImage }),
  };
}
