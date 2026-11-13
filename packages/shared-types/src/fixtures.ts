import data from "../fixtures/referrals.json";
import { referralSchema } from "./index";
export const demoReferrals = data.map(record => referralSchema.parse(record));
