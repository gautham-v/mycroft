ALTER TYPE "public"."source_kind" ADD VALUE 'podcast';--> statement-breakpoint
ALTER TABLE "items" ADD COLUMN "audio_url" text;