import { neon } from "@neondatabase/serverless";
import { drizzle, type NeonHttpDatabase } from "drizzle-orm/neon-http";
import * as schema from "./schema";
import { seedSources } from "./seed";

export type DB = NeonHttpDatabase<typeof schema>;

let _db: DB | null = null;
let _ready: Promise<void> | null = null;

const SCHEMA_SQL = [
  `IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'source_kind') THEN CREATE TYPE "source_kind" AS ENUM ('rss', 'youtube', 'page'); END IF`,
  // Scraped-page sources (kind 'page'), added after the first release.
  `ALTER TYPE "source_kind" ADD VALUE IF NOT EXISTS 'page'`,
  `CREATE TABLE IF NOT EXISTS "sources" (
    "id" serial PRIMARY KEY NOT NULL,
    "title" text NOT NULL,
    "url" text NOT NULL,
    "feed_url" text NOT NULL,
    "kind" "source_kind" NOT NULL,
    "group" text NOT NULL,
    "icon_url" text,
    "last_fetched_at" timestamp with time zone,
    "last_error" text,
    "seen_urls" text[],
    "created_at" timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT "sources_feed_url_unique" UNIQUE("feed_url")
  )`,
  `CREATE TABLE IF NOT EXISTS "items" (
    "id" serial PRIMARY KEY NOT NULL,
    "source_id" integer NOT NULL REFERENCES "sources"("id") ON DELETE cascade,
    "guid" text NOT NULL,
    "url" text NOT NULL,
    "title" text NOT NULL,
    "summary" text,
    "content_html" text,
    "content_rendered" boolean DEFAULT false NOT NULL,
    "author" text,
    "published_at" timestamp with time zone NOT NULL,
    "thumbnail_url" text,
    "video_id" text,
    "duration_sec" integer,
    "hn_points" integer,
    "hn_comments" integer,
    "hn_comments_url" text,
    "is_saved" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT now() NOT NULL
  )`,
  `CREATE TABLE IF NOT EXISTS "meta" ("key" text PRIMARY KEY NOT NULL, "value" text NOT NULL)`,
  `CREATE UNIQUE INDEX IF NOT EXISTS "items_source_guid_uq" ON "items" ("source_id","guid")`,
  `CREATE INDEX IF NOT EXISTS "items_published_at_idx" ON "items" ("published_at" DESC NULLS LAST)`,
  // Read/unread was removed; drop the column (and its index) from databases created before that.
  `DROP INDEX IF EXISTS "items_is_read_idx"`,
  `ALTER TABLE "items" DROP COLUMN IF EXISTS "is_read"`,
  `ALTER TABLE "sources" ADD COLUMN IF NOT EXISTS "seen_urls" text[]`,
  // Remembers that a cached copy came from the rendered fallback, so the label survives reloads.
  `ALTER TABLE "items" ADD COLUMN IF NOT EXISTS "content_rendered" boolean DEFAULT false NOT NULL`,
];

function rawDb(): DB {
  if (_db) return _db;
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set");
  _db = drizzle(neon(url), { schema });
  return _db;
}

/** The whole schema as one DO block (exported for tests). */
export function schemaSql(): string {
  const body = SCHEMA_SQL.join(";\n");
  return `DO $outer$ BEGIN PERFORM pg_advisory_xact_lock(727); ${body}; END $outer$`;
}

/** Idempotently create tables (no migration step on Vercel+Neon import). */
export async function ensureSchema(): Promise<void> {
  const url = process.env.DATABASE_URL;
  if (!url) throw new Error("DATABASE_URL is not set");
  const sql = neon(url);
  // One statement = one transaction on neon-http; the advisory lock serialises
  // concurrent cold starts so CREATE ... IF NOT EXISTS can't race on pg_type.
  const locked = schemaSql();
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      await sql.query(locked);
      return;
    } catch (e) {
      const code = (e as { code?: string }).code;
      if (attempt === 1 || !(code === "23505" || code === "42P07" || code === "42710")) throw e;
    }
  }
}

/** Returns a ready DB: schema ensured and sources seeded once per cold start. */
export async function getDb(): Promise<DB> {
  const db = rawDb();
  if (!_ready) {
    _ready = (async () => {
      await ensureSchema();
      // No-op once the meta "seeded" flag exists, so user removals stick.
      await seedSources(db);
    })().catch((e) => {
      _ready = null;
      throw e;
    });
  }
  await _ready;
  return db;
}

export { schema };
