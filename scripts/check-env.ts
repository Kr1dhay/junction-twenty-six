/**
 * Prints which backend features the current environment supports and the variable names still missing.
 * Never prints values. Exit code 1 if anything fatal is missing.
 *   pnpm env:check                      # reads apps/crm-web/.env.local if present
 *   VERCEL=1 pnpm env:check             # evaluate with hosted rules
 */
import { checkEnvironment, logEnvironment } from "../apps/crm-web/src/server/env-check";

const statuses = checkEnvironment();
logEnvironment(statuses);
process.exitCode = statuses.some(status => status.severity === "fatal") ? 1 : 0;
