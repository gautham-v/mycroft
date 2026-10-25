import { eq, sql } from "drizzle-orm";
import type { DB } from "@/db/client";
import { meta } from "@/db/schema";

/**
 * Post sources (X/Twitter, Bluesky, Threads, Mastodon profiles). Used both in TS and as a
 * Postgres regex (`~*`), so keep the syntax common to both: no lookarounds, no named classes.
 */
export const POST_SOURCE_RE = "^https?://(www\\.|mobile\\.)?(x\\.com|twitter\\.com|bsky\\.app|threads\\.net|mastodon\\.[a-z]+)/";

export function isPostSource(url: string): boolean {
  return new RegExp(POST_SOURCE_RE, "i").test(url);
}

const SEEDED_KEY = "folders_seeded";

/** Default folders for the first run, keyed by the legacy `group` column (youtube/posts by kind/url). */
const BACKFILL = sql.raw(`
  WITH f AS (
    INSERT INTO "folders" ("title", "position")
    VALUES ('Labs', 0), ('Blogs', 1), ('News', 2), ('Posts', 3), ('YouTube', 4)
    RETURNING "id", "title"
  ),
  target AS (
    SELECT s."id" AS sid,
      CASE
        WHEN s."url" ~* '${POST_SOURCE_RE}' THEN 'Posts'
        WHEN s."kind" = 'youtube' THEN 'YouTube'
        WHEN s."group" = 'labs' THEN 'Labs'
        WHEN s."group" = 'blogs' THEN 'Blogs'
        WHEN s."group" IN ('news', 'aggregator') THEN 'News'
      END AS title
    FROM "sources" s
  )
  UPDATE "sources" s SET "folder_id" = f."id"
  FROM target t JOIN f ON f."title" = t.title
  WHERE s."id" = t.sid
`);

const PRUNE_EMPTY = sql.raw(`DELETE FROM "folders" WHERE "id" NOT IN (SELECT "folder_id" FROM "sources" WHERE "folder_id" IS NOT NULL)`);

const NUMBER_POSITIONS = sql.raw(`
  UPDATE "sources" s SET "position" = r.rn
  FROM (SELECT "id", row_number() OVER (PARTITION BY "folder_id" ORDER BY lower("title")) - 1 AS rn FROM "sources") r
  WHERE r."id" = s."id"
`);

/** Create the default folders and file every source into one. Runs once per database (meta flag). */
export async function seedFolders(db: DB): Promise<void> {
  const [row] = await db.select().from(meta).where(eq(meta.key, SEEDED_KEY));
  if (row) return;
  await db.execute(BACKFILL);
  await db.execute(PRUNE_EMPTY);
  await db.execute(NUMBER_POSITIONS);
  await db.insert(meta).values({ key: SEEDED_KEY, value: new Date().toISOString() }).onConflictDoNothing();
}
