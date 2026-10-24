CREATE TYPE "public"."source_kind" AS ENUM('rss', 'youtube');--> statement-breakpoint
CREATE TABLE "items" (
	"id" serial PRIMARY KEY NOT NULL,
	"source_id" integer NOT NULL,
	"guid" text NOT NULL,
	"url" text NOT NULL,
	"title" text NOT NULL,
	"summary" text,
	"content_html" text,
	"author" text,
	"published_at" timestamp with time zone NOT NULL,
	"thumbnail_url" text,
	"video_id" text,
	"duration_sec" integer,
	"hn_points" integer,
	"hn_comments" integer,
	"hn_comments_url" text,
	"is_read" boolean DEFAULT false NOT NULL,
	"is_saved" boolean DEFAULT false NOT NULL,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL
);
--> statement-breakpoint
CREATE TABLE "meta" (
	"key" text PRIMARY KEY NOT NULL,
	"value" text NOT NULL
);
--> statement-breakpoint
CREATE TABLE "sources" (
	"id" serial PRIMARY KEY NOT NULL,
	"title" text NOT NULL,
	"url" text NOT NULL,
	"feed_url" text NOT NULL,
	"kind" "source_kind" NOT NULL,
	"group" text NOT NULL,
	"icon_url" text,
	"last_fetched_at" timestamp with time zone,
	"last_error" text,
	"created_at" timestamp with time zone DEFAULT now() NOT NULL,
	CONSTRAINT "sources_feed_url_unique" UNIQUE("feed_url")
);
--> statement-breakpoint
ALTER TABLE "items" ADD CONSTRAINT "items_source_id_sources_id_fk" FOREIGN KEY ("source_id") REFERENCES "public"."sources"("id") ON DELETE cascade ON UPDATE no action;--> statement-breakpoint
CREATE UNIQUE INDEX "items_source_guid_uq" ON "items" USING btree ("source_id","guid");--> statement-breakpoint
CREATE INDEX "items_published_at_idx" ON "items" USING btree ("published_at" DESC NULLS LAST);--> statement-breakpoint
CREATE INDEX "items_is_read_idx" ON "items" USING btree ("is_read");