import { Pool, neonConfig, type PoolClient } from "@neondatabase/serverless";
import WebSocket from "ws";
import { isDeepStrictEqual } from "node:util";
import { toCRMConsultation, toCRMReferral, type ConsultationRecord, type ReferralRecord, type CommitmentAccount } from "@edgecare/shared-types";
import { ConflictError, MissingError } from "./repository";
import { preservesReferralIdentity } from "./referral-update";

neonConfig.webSocketConstructor = WebSocket;
type Row = { id: string; payload: ReferralRecord | null; hash: string | null; spent: boolean; created_slot: string | null; spent_slot: string | null; spent_at: string | null; operation_id: string | null };

// Interactive transactions serialize every mutation for a referral, including creation
// when neither table contains a row yet. Connections never outlive an operation.
export class PostgresRepository {
  private initialized?: Promise<void>;
  constructor(private connectionString: string, private now: () => Date = () => new Date()) {}
  private async connection<T>(action: (client: PoolClient) => Promise<T>): Promise<T> {
    const pool = new Pool({ connectionString: this.connectionString, max: 1, connectionTimeoutMillis: 15000 });
    try {
      const client = await pool.connect();
      try { return await action(client); } finally { client.release(); }
    } finally { await pool.end(); }
  }
  async ready() {
    if (!this.initialized) {
      this.initialized = this.connection(async client => {
        await client.query("BEGIN");
        try {
          await client.query("SELECT pg_advisory_xact_lock(1650740387, 0)");
          await client.query(`CREATE TABLE IF NOT EXISTS edgecare_demo_referrals (id TEXT PRIMARY KEY, payload JSONB NOT NULL);
            CREATE TABLE IF NOT EXISTS edgecare_demo_commitments (id TEXT PRIMARY KEY, hash TEXT NOT NULL CHECK (hash ~ '^[a-f0-9]{64}$'), spent BOOLEAN NOT NULL DEFAULT FALSE, created_slot BIGINT NOT NULL, spent_slot BIGINT, spent_at TEXT, operation_id TEXT);
            CREATE TABLE IF NOT EXISTS edgecare_demo_consultations (id TEXT PRIMARY KEY, referral_id TEXT NOT NULL, started_at TEXT NOT NULL, payload JSONB NOT NULL);
            CREATE INDEX IF NOT EXISTS edgecare_demo_consultations_referral ON edgecare_demo_consultations (referral_id, started_at);`);
          await client.query("COMMIT");
        } catch (error) { await client.query("ROLLBACK"); throw error; }
      }).catch(error => { this.initialized = undefined; throw error; });
    }
    await this.initialized;
  }
  async ping() {
    await this.ready();
    await this.connection(async client => { await client.query("SELECT 1"); });
  }
  private async mutate<T>(id: string, action: (client: PoolClient) => Promise<T>): Promise<T> {
    await this.ready();
    return this.connection(async client => {
      await client.query("BEGIN");
      try {
        await client.query("SELECT pg_advisory_xact_lock(1650740388, hashtext($1))", [id]);
        const result = await action(client);
        await client.query("COMMIT");
        return result;
      } catch (error) { await client.query("ROLLBACK"); throw error; }
    });
  }
  private async envelope(client: PoolClient, id: string) {
    return (await client.query<{ payload: ReferralRecord }>("SELECT payload FROM edgecare_demo_referrals WHERE id = $1", [id])).rows[0]?.payload;
  }
  create(record: ReferralRecord): Promise<{ created: boolean }>;
  create(id: string, hash: string): Promise<void>;
  async create(input: ReferralRecord | string, hash?: string): Promise<{ created: boolean } | void> {
    const id = typeof input === "string" ? input : input.referral_id;
    return this.mutate(id, async client => {
      const record = await this.envelope(client, id);
      const account = (await client.query<{ hash: string }>("SELECT hash FROM edgecare_demo_commitments WHERE id = $1", [id])).rows[0];
      if (typeof input === "string") {
        if (!hash || !/^[a-f0-9]{64}$/.test(hash)) throw new Error("Invalid commitment hash");
        if (account) {
          if (account.hash !== hash) throw new ConflictError("Commitment already exists with different content");
          return;
        }
        if (record && record.commitment_hash !== hash) throw new ConflictError("Enrollment commitment hash does not match");
        await client.query("INSERT INTO edgecare_demo_commitments (id, hash, created_slot) VALUES ($1, $2, $3)", [id, hash, this.now().getTime()]);
        return;
      }
      if (record) {
        if (!isDeepStrictEqual(record, input)) throw new ConflictError("Referral already exists with different content");
        return { created: false };
      }
      if (account && account.hash !== input.commitment_hash) throw new ConflictError("Registry commitment hash does not match");
      if (input.status !== "open") throw new Error("New referrals must be open");
      await client.query("INSERT INTO edgecare_demo_referrals (id, payload) VALUES ($1, $2::jsonb)", [id, JSON.stringify(input)]);
      return { created: true };
    });
  }
  async verificationEnvelope(id: string) {
    await this.ready();
    return this.connection(client => this.envelope(client, id));
  }
  async update(expected: ReferralRecord, record: ReferralRecord) {
    if (!preservesReferralIdentity(expected, record)) throw new ConflictError("An update cannot change referral identity, credentials, expiry or status");
    await this.mutate(record.referral_id, async client => {
      const current = await this.envelope(client, record.referral_id);
      if (!current) throw new MissingError("Referral not found");
      if (isDeepStrictEqual(current, record)) return;
      if (!isDeepStrictEqual(current, expected)) throw new ConflictError("Referral changed. Verify and reload it before editing again");
      await client.query("UPDATE edgecare_demo_referrals SET payload = $2::jsonb WHERE id = $1", [record.referral_id, JSON.stringify(record)]);
    });
  }
  async read(id: string): Promise<CommitmentAccount | undefined> {
    await this.ready();
    return this.connection(async client => {
      const row = (await client.query<Row>("SELECT * FROM edgecare_demo_commitments WHERE id = $1", [id])).rows[0];
      return row ? { commitment_hash: row.hash!, spent: row.spent, created_slot: Number(row.created_slot), spent_slot: row.spent_slot === null ? null : Number(row.spent_slot) } : undefined;
    });
  }
  async spend(id: string, expectedHash?: string, operationID?: string) {
    await this.mutate(id, async client => {
      const row = (await client.query<Row>("SELECT * FROM edgecare_demo_commitments WHERE id = $1", [id])).rows[0];
      if (!row) throw new MissingError("Commitment not found");
      if (expectedHash && row.hash !== expectedHash) throw new ConflictError("Commitment hash does not match");
      if (row.spent && operationID && row.operation_id === operationID) return;
      const record = await this.envelope(client, id);
      if (record && new Date(record.expires_at) <= this.now() && !row.spent) throw new ConflictError("Referral has expired");
      const time = this.now();
      const result = await client.query("UPDATE edgecare_demo_commitments SET spent = TRUE, spent_slot = $2, spent_at = $3, operation_id = $4 WHERE id = $1 AND spent = FALSE", [id, time.getTime(), time.toISOString(), operationID ?? null]);
      if (result.rowCount !== 1) throw new ConflictError("Commitment already spent");
    });
  }
  private crm(row: Row) {
    const record = row.payload!;
    const spent = row.hash === record.commitment_hash && row.spent;
    const status = spent ? "spent" : new Date(record.expires_at) <= this.now() ? "expired" : "open";
    const history: { status: "open" | "spent" | "expired"; at: string }[] = [{ status: "open", at: record.created_at }];
    if (status === "expired") history.push({ status, at: record.expires_at });
    if (spent) history.push({ status: "spent", at: row.spent_at! });
    return toCRMReferral({ ...record, status }, history);
  }
  async get(id: string) {
    await this.ready();
    return this.connection(async client => {
      const row = (await client.query<Row>("SELECT r.id, r.payload, c.hash, c.spent, c.spent_at FROM edgecare_demo_referrals r LEFT JOIN edgecare_demo_commitments c USING (id) WHERE r.id = $1", [id])).rows[0];
      return row ? this.crm(row) : undefined;
    });
  }
  async list() {
    await this.ready();
    return this.connection(async client => (await client.query<Row>("SELECT r.id, r.payload, c.hash, c.spent, c.spent_at FROM edgecare_demo_referrals r LEFT JOIN edgecare_demo_commitments c USING (id) ORDER BY r.payload->>'created_at' DESC, r.id")).rows.map(row => this.crm(row)));
  }
  /** Serialized per consultation; append-only and idempotent on consultation_id. */
  async createConsultation(record: ConsultationRecord): Promise<{ created: boolean }> {
    return this.mutate(`consultation:${record.consultation_id}`, async client => {
      if (!await this.envelope(client, record.referral_id)) throw new MissingError("Referral not found");
      const existing = (await client.query<{ payload: ConsultationRecord }>("SELECT payload FROM edgecare_demo_consultations WHERE id = $1", [record.consultation_id])).rows[0];
      if (existing) {
        if (!isDeepStrictEqual(existing.payload, record)) throw new ConflictError("Consultation already exists with different content");
        return { created: false };
      }
      await client.query("INSERT INTO edgecare_demo_consultations (id, referral_id, started_at, payload) VALUES ($1, $2, $3, $4::jsonb)", [record.consultation_id, record.referral_id, record.started_at, JSON.stringify(record)]);
      return { created: true };
    });
  }
  async listConsultations(referralID: string) {
    await this.ready();
    return this.connection(async client => (await client.query<{ payload: ConsultationRecord }>("SELECT payload FROM edgecare_demo_consultations WHERE referral_id = $1 ORDER BY started_at DESC, id", [referralID])).rows.map(row => toCRMConsultation(row.payload)));
  }
}
