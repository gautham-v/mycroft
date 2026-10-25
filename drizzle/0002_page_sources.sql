ALTER TYPE "public"."source_kind" ADD VALUE 'page';--> statement-breakpoint
ALTER TABLE "sources" ADD COLUMN "seen_urls" text[];