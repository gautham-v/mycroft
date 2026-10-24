import {
  pgTable,
  pgEnum,
  serial,
  text,
  timestamp,
  integer,
  boolean,
  uniqueIndex,
  index,
} from "drizzle-orm/pg-core";

export const sourceKind = pgEnum("source_kind", ["rss", "youtube"]);

export const sources = pgTable("sources", {
  id: serial("id").primaryKey(),
  title: text("title").notNull(),
  url: text("url").notNull(),
  feedUrl: text("feed_url").notNull().unique(),
  kind: sourceKind("kind").notNull(),
  group: text("group").notNull(),
  iconUrl: text("icon_url"),
  lastFetchedAt: timestamp("last_fetched_at", { withTimezone: true }),
  lastError: text("last_error"),
  createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
});

export const items = pgTable(
  "items",
  {
    id: serial("id").primaryKey(),
    sourceId: integer("source_id")
      .notNull()
      .references(() => sources.id, { onDelete: "cascade" }),
    guid: text("guid").notNull(),
    url: text("url").notNull(),
    title: text("title").notNull(),
    summary: text("summary"),
    contentHtml: text("content_html"),
    author: text("author"),
    publishedAt: timestamp("published_at", { withTimezone: true }).notNull(),
    thumbnailUrl: text("thumbnail_url"),
    videoId: text("video_id"),
    durationSec: integer("duration_sec"),
    hnPoints: integer("hn_points"),
    hnComments: integer("hn_comments"),
    hnCommentsUrl: text("hn_comments_url"),
    isSaved: boolean("is_saved").notNull().default(false),
    createdAt: timestamp("created_at", { withTimezone: true }).notNull().defaultNow(),
  },
  (t) => [
    uniqueIndex("items_source_guid_uq").on(t.sourceId, t.guid),
    index("items_published_at_idx").on(t.publishedAt.desc()),
  ],
);

export const meta = pgTable("meta", {
  key: text("key").primaryKey(),
  value: text("value").notNull(),
});

export type SourceRow = typeof sources.$inferSelect;
export type ItemRow = typeof items.$inferSelect;
export type NewItemRow = typeof items.$inferInsert;
