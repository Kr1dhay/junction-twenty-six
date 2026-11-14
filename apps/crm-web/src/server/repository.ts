import Database from "better-sqlite3";
import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { isDeepStrictEqual } from "node:util";
import { toCRMReferral, type ChainClient, type CommitmentAccount, type ReferralRecord, type ReferralRepository } from "@edgecare/shared-types";
import { offeredSlots, eligibleSlot, makeAppointment, type Appointment } from "./appointments";
import { preservesReferralIdentity } from "./referral-update";

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
    this.db.exec(`CREATE TABLE IF NOT EXISTS appointments (id TEXT PRIMARY KEY, referral_id TEXT NOT NULL, slot_id TEXT NOT NULL, starts_at TEXT NOT NULL, active INTEGER NOT NULL, payload TEXT NOT NULL);
      CREATE UNIQUE INDEX IF NOT EXISTS appointments_slot_active ON appointments(slot_id) WHERE active = 1;
      CREATE UNIQUE INDEX IF NOT EXISTS appointments_referral_active ON appointments(referral_id) WHERE active = 1;`);
    const columns = this.db.prepare("PRAGMA table_info(commitments)").all() as { name: string }[];
    if (!columns.some(column => column.name === "operation_id")) this.db.exec("ALTER TABLE commitments ADD COLUMN operation_id TEXT");
  }
  close() { this.db.close(); }
  appointmentSlots() {
    const taken = new Set((this.db.prepare("SELECT slot_id FROM appointments WHERE active = 1 AND starts_at > ?").all(this.now().toISOString()) as { slot_id: string }[]).map(row => row.slot_id));
    return offeredSlots(this.now()).filter(slot => !taken.has(slot.slot_id));
  }
  appointmentFor(id: string): Appointment | undefined {
    const row = this.db.prepare("SELECT payload FROM appointments WHERE referral_id = ? AND active = 1 AND starts_at > ?").get(id, this.now().toISOString()) as { payload: string } | undefined;
    return row ? JSON.parse(row.payload) as Appointment : undefined;
  }
  bookAppointment(id: string, slotID: string, operationID: string): Appointment {
    return this.db.transaction(() => {
      const old = this.db.prepare("SELECT payload FROM appointments WHERE id = ?").get(operationID) as { payload: string } | undefined;
      if (old) {
        const booking = JSON.parse(old.payload) as Appointment;
        if (booking.referral_id !== id || booking.slot_id !== slotID) throw new ConflictError("Booking operation already used");
        return booking;
      }
      const record = this.verificationEnvelope(id);
      if (!record) throw new MissingError("Referral not found");
      const now = this.now(), slot = eligibleSlot(record, slotID, now);
      if (!slot) throw new ConflictError("Slot is no longer available or referral has expired");
      this.db.prepare("UPDATE appointments SET active = 0, payload = json_set(payload, '$.status', 'completed') WHERE referral_id = ? AND active = 1 AND starts_at <= ?").run(id, now.toISOString());
      const booking = makeAppointment(record, slot, operationID, now);
      try {
        this.db.prepare("INSERT INTO appointments (id, referral_id, slot_id, starts_at, active, payload) VALUES (?, ?, ?, ?, 1, ?)").run(operationID, id, slotID, slot.starts_at, JSON.stringify(booking));
      } catch (error) {
        if ((error as { code?: string }).code?.startsWith("SQLITE_CONSTRAINT")) throw new ConflictError("Slot was taken or this referral already has an appointment");
        throw error;
      }
      return booking;
    }).immediate();
  }
  cancelAppointment(id: string, appointmentID: string): Appointment {
    return this.db.transaction(() => {
      const row = this.db.prepare("SELECT payload FROM appointments WHERE id = ? AND referral_id = ?").get(appointmentID, id) as { payload: string } | undefined;
      if (!row) throw new MissingError("Appointment not found");
      const booking = JSON.parse(row.payload) as Appointment;
      if (booking.status === "cancelled") return booking;
      if (booking.starts_at <= this.now().toISOString()) throw new ConflictError("Appointment has already started");
      const cancelled: Appointment = { ...booking, status: "cancelled" };
      this.db.prepare("UPDATE appointments SET active = 0, payload = ? WHERE id = ?").run(JSON.stringify(cancelled), appointmentID);
      return cancelled;
    }).immediate();
  }
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
  update(expected: ReferralRecord, record: ReferralRecord) {
    if (!preservesReferralIdentity(expected, record)) throw new ConflictError("An update cannot change referral identity, credentials, expiry or status");
    this.db.transaction(() => {
      const current = this.verificationEnvelope(record.referral_id);
      if (!current) throw new MissingError("Referral not found");
      if (isDeepStrictEqual(current, record)) return; // Retry after a lost response.
      if (!isDeepStrictEqual(current, expected)) throw new ConflictError("Referral changed. Verify and reload it before editing again");
      this.db.prepare("UPDATE referrals SET payload = ? WHERE id = ?").run(JSON.stringify(record), record.referral_id);
    }).immediate();
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
