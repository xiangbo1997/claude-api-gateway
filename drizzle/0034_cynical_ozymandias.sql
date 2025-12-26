ALTER TABLE "providers" ADD COLUMN "upstream_balance" numeric(15, 6);--> statement-breakpoint
ALTER TABLE "providers" ADD COLUMN "balance_last_updated" timestamp with time zone;--> statement-breakpoint
ALTER TABLE "providers" ADD COLUMN "balance_api_endpoint" varchar(512);--> statement-breakpoint
ALTER TABLE "providers" ADD COLUMN "balance_fetch_enabled" boolean DEFAULT false;