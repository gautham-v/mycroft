import { getDb } from "../src/db/client";
import { seedSources } from "../src/db/seed";

async function main() {
  const db = await getDb();
  await seedSources(db);
  console.log("Seeded sources.");
}
main().catch((e) => {
  console.error(e);
  process.exit(1);
});
