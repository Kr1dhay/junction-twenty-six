import { demoReferrals } from "@edgecare/shared-types/fixtures";
import { DemoRepository } from "./repository";
import { requireDemoMode } from "./config";
let repository: DemoRepository | undefined;
export function backend() {
  requireDemoMode();
  if (!repository) {
    repository = new DemoRepository(process.env.EDGECARE_DB_PATH ?? ".data/edgecare.sqlite");
    for (const referral of demoReferrals) {
      repository.create(referral);
      repository.create(referral.referral_id, referral.commitment_hash);
    }
  }
  return repository;
}
