import { ConflictError, DemoRepository } from "../../src/server/repository";
const [path, id, hash, operation] = process.argv.slice(2);
if (!path || !id || !hash || !operation) throw new Error("Missing worker input");
const repository = new DemoRepository(path, () => new Date("2026-11-14T12:00:00.000Z"));
try {
  repository.create(id, hash);
  repository.spend(id, hash, operation);
  process.stdout.write("accepted");
} catch (error) {
  if (error instanceof ConflictError) process.stdout.write("conflict");
  else throw error;
} finally { repository.close(); }
