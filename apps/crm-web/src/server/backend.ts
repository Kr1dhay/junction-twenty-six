import { demoReferrals } from "@edgecare/shared-types/fixtures";
import { PostgresRepository } from "./postgres-repository";
import { DemoRepository } from "./repository";
import { requireDemoMode } from "./config";
let repository: DemoRepository | undefined;
let hostedRepository: PostgresRepository | undefined;
export function backend() {
  requireDemoMode();
  if (process.env.DATABASE_URL) {
    hostedRepository ??= new PostgresRepository(process.env.DATABASE_URL);
    return hostedRepository;
  }
  if (process.env.VERCEL === "1") throw new Error("Hosted demo requires DATABASE_URL");
  if (!repository) {
    repository = new DemoRepository(process.env.EDGECARE_DB_PATH ?? ".data/edgecare.sqlite");
    for (const referral of demoReferrals) {
      repository.create(referral);
      repository.create(referral.referral_id, referral.commitment_hash);
    }
  }
  return repository;
}
