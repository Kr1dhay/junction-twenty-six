import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { toCRMReferral, type ChainClient, type CommitmentAccount, type ReferralRecord, type ReferralRepository } from "@edgecare/shared-types";

export class ConflictError extends Error {}
export class MissingError extends Error {}

// One durable SQLite adapter for local synthetic demos; replace behind the interfaces for deployment.
export class DemoRepository implements ReferralRepository, ChainClient {
  private db: Database.Database;
  constructor(path: string, private now: () => Date = () => new Date()) {
    if (path !== ":memory:") mkdirSync(dirname(path), { recursive: true });
    this.db = new Database(path);
    this.db.pragma("journal_mode = WAL");
    this.db.pragma("busy_timeout = 5000");
    this.db.exec(`CREATE TABLE IF NOT EXISTS referrals (id TEXT PRIMARY KEY, payload TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS commitments (id TEXT PRIMARY KEY, hash TEXT NOT NULL, spent INTEGER NOT NULL DEFAULT 0, created_slot INTEGER NOT NULL, spent_slot INTEGER, spent_at TEXT, operation_id TEXT);`);
    const columns = this.db.prepare("PRAGMA table_info(commitments)").all() as { name: string }[];
    if (!columns.some(column => column.name === "operation_id")) this.db.exec("ALTER TABLE commitments ADD COLUMN operation_id TEXT");
  }
  close() { this.db.close(); }
  // Overloads expose the two independent interfaces without duplicating storage.
  create(record: ReferralRecord): { created: boolean };
  create(id: string, hash: string): void;
  create(input: ReferralRecord | string, hash?: string): { created: boolean } | void {
    if (typeof input === "string") {
      if (!hash || !/^[a-f0-9]{64}$/.test(hash)) throw new Error("Invalid commitment hash");
      this.db.transaction(() => {
        const old = this.read(input);
        if (old) {
          if (old.commitment_hash !== hash) throw new ConflictError("Commitment already exists with different content");
          return; // Enrollment retries remain idempotent after a later spend.
        }
        const record = this.verificationEnvelope(input);
        if (record && record.commitment_hash !== hash) throw new ConflictError("Enrollment commitment hash does not match");
        this.db.prepare("INSERT INTO commitments (id, hash, created_slot) VALUES (?, ?, ?)").run(input, hash, this.now().getTime());
      }).immediate();
      return;
    }
    return this.db.transaction(() => {
      const old = this.verificationEnvelope(input.referral_id);
      if (old) {
        if (!isDeepStrictEqual(old, input)) throw new ConflictError("Referral already exists with different content");
        return { created: false };
      }
      const chain = this.read(input.referral_id);
      if (chain && chain.commitment_hash !== input.commitment_hash) throw new ConflictError("Registry commitment hash does not match");
      if (input.status !== "open") throw new Error("New referrals must be open");
      this.db.prepare("INSERT INTO referrals VALUES (?, ?)").run(input.referral_id, JSON.stringify(input));
      return { created: true };
    }).immediate();
  }
  read(id: string): CommitmentAccount | undefined {
    const row = this.db.prepare("SELECT * FROM commitments WHERE id = ?").get(id) as { hash: string; spent: number; created_slot: number; spent_slot: number | null } | undefined;
    return row && { commitment_hash: row.hash, spent: !!row.spent, created_slot: row.created_slot, spent_slot: row.spent_slot };
  }
  spend(id: string, expectedHash?: string, operationID?: string) {
    this.db.transaction(() => {
      const account = this.read(id);
      if (!account) throw new MissingError("Commitment not found");
      if (expectedHash && account.commitment_hash !== expectedHash) throw new ConflictError("Commitment hash does not match");
      if (account.spent && operationID) {
        const row = this.db.prepare("SELECT operation_id FROM commitments WHERE id = ?").get(id) as { operation_id: string | null };
        if (row.operation_id === operationID) return;
      }
      const record = this.verificationEnvelope(id);
      if (record && new Date(record.expires_at) <= this.now() && !account.spent) throw new ConflictError("Referral has expired");
      const time = this.now();
      const result = this.db.prepare("UPDATE commitments SET spent = 1, spent_slot = ?, spent_at = ?, operation_id = ? WHERE id = ? AND spent = 0").run(time.getTime(), time.toISOString(), operationID ?? null, id);
      if (result.changes !== 1) throw new ConflictError("Commitment already spent");
    }).immediate();
  }
  verificationEnvelope(id: string): ReferralRecord | undefined {
    const row = this.db.prepare("SELECT payload FROM referrals WHERE id = ?").get(id) as { payload: string } | undefined;
    return row ? JSON.parse(row.payload) as ReferralRecord : undefined;
  }
  get(id: string) {
    const record = this.verificationEnvelope(id);
    if (!record) return undefined;
    const chain = this.read(id);
    const spent = chain?.commitment_hash === record.commitment_hash && chain.spent;
    const status = spent ? "spent" : new Date(record.expires_at) <= this.now() ? "expired" : "open";
    const history: { status: "open" | "spent" | "expired"; at: string }[] = [{ status: "open", at: record.created_at }];
    if (status === "expired") history.push({ status, at: record.expires_at });
    if (spent) {
      const row = this.db.prepare("SELECT spent_at FROM commitments WHERE id = ?").get(id) as { spent_at: string };
      history.push({ status: "spent", at: row.spent_at });
    }
    return toCRMReferral({ ...record, status }, history);
  }
  list() {
    const rows = this.db.prepare("SELECT id FROM referrals ORDER BY json_extract(payload, '$.created_at') DESC, id").all() as { id: string }[];
    return rows.map(row => this.get(row.id)!);
  }
}
