import { mkdirSync, writeFileSync } from "node:fs";
import { z } from "zod";
import { referralSchema } from "../packages/shared-types/src/index";
mkdirSync("packages/shared-types/schema", { recursive: true });
writeFileSync("packages/shared-types/schema/referral.schema.json", JSON.stringify(z.toJSONSchema(referralSchema, { io: "input", unrepresentable: "any" }), null, 2) + "\n");
