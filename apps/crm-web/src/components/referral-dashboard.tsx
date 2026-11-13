"use client";
import { useEffect, useState } from "react";
import type { CRMReferral } from "@edgecare/shared-types";

export function ReferralDashboard() {
  const [referrals, setReferrals] = useState<CRMReferral[]>([]);
  const [selected, setSelected] = useState<string>();
  const [error, setError] = useState<string>();
  const [loaded, setLoaded] = useState(false);
  const [status, setStatus] = useState("");
  const [risk, setRisk] = useState("");
  const [specialty, setSpecialty] = useState("");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  useEffect(() => {
    const controller = new AbortController();
    let running = false;
    async function refresh() {
      if (running) return;
      running = true;
      try {
        const response = await fetch("/referrals", { cache: "no-store", signal: controller.signal });
        if (!response.ok) throw new Error("Cannot load referrals. Check the local backend and demo configuration.");
        const data = await response.json() as { referrals: CRMReferral[] };
        setReferrals(data.referrals); setError(undefined); setLoaded(true);
      } catch (cause) {
        if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : "Connection unavailable");
      } finally { running = false; }
    }
    void refresh(); const timer = setInterval(() => void refresh(), 3000);
    return () => { controller.abort(); clearInterval(timer); };
  }, []);
  const visible = referrals.filter(record => (!status || record.status === status) && (!risk || record.risk_band === risk)
    && (!specialty || record.recommended_specialty === specialty) && (!from || record.created_at.slice(0, 10) >= from)
    && (!to || record.created_at.slice(0, 10) <= to));
  const detail = referrals.find(record => record.referral_id === selected);
  return <main className="mx-auto max-w-6xl space-y-8 p-6 md:p-10">
    <header><p className="text-sm text-neutral-600">EDGE-CARE · BRAND PLACEHOLDER</p><h1 className="mt-2 text-3xl font-semibold">Anonymous referrals</h1>
      <p className="mt-3 text-neutral-700">Doctor workspace · synthetic demo data · local registry</p></header>
    <section aria-label="Filters" className="flex flex-wrap gap-4">
      <label className="grid gap-1">Status<select value={status} onChange={event => setStatus(event.target.value)}><option value="">All statuses</option>{["open", "spent", "expired"].map(value => <option key={value}>{value}</option>)}</select></label>
      <label className="grid gap-1">Risk band<select value={risk} onChange={event => setRisk(event.target.value)}><option value="">All bands</option>{["low", "medium", "high"].map(value => <option key={value}>{value}</option>)}</select></label>
      <label className="grid gap-1">Specialty<select value={specialty} onChange={event => setSpecialty(event.target.value)}><option value="">All specialties</option>{[...new Set(referrals.map(record => record.recommended_specialty))].sort().map(value => <option key={value}>{value}</option>)}</select></label>
      <label className="grid gap-1">From<input type="date" value={from} onChange={event => setFrom(event.target.value)} /></label>
      <label className="grid gap-1">To<input type="date" value={to} onChange={event => setTo(event.target.value)} /></label>
    </section>
    {error && <p role="alert" className="rounded-lg border p-4">{error}</p>}
    {!loaded && !error && <p role="status">Loading referrals…</p>}
    <div className="grid items-start gap-6 lg:grid-cols-2"><section aria-label="Referral list" className="space-y-3">
      {loaded && !visible.length && <p>No referrals match these filters.</p>}
      {visible.map(record => <button key={record.referral_id} onClick={() => setSelected(record.referral_id)} aria-pressed={selected === record.referral_id} className="block w-full space-y-2 p-5 text-left">
        <span className="flex justify-between gap-3"><strong>{record.referral_id.slice(0, 8)}</strong><span>{record.status} · {record.risk_band} risk</span></span>
        <span className="block">{record.free_text_summary}</span><span className="block text-sm text-neutral-600">{record.recommended_specialty} · {record.language} · {record.created_at.slice(0, 10)}</span>
      </button>)}
    </section><aside aria-label="Referral details" className="rounded-xl border border-neutral-300 bg-white p-6">
      {detail ? <><h2 className="text-xl font-semibold">Referral details</h2><p className="mt-2 break-all font-mono text-sm">{detail.referral_id}</p>
        <dl className="mt-6 space-y-4">{[["Summary", detail.free_text_summary], ["Patient guidance", detail.patient_language_summary], ["Risk", `${detail.risk_band} (${detail.risk_score}/100) · demo only`], ["Letter", detail.letter_scan.extracted_text ?? "No extracted text"], ["Lesion", detail.lesion_photo.assessment ?? "No assessment"], ["Expires", detail.expires_at]].map(([label, value]) => <div key={label}><dt className="font-semibold">{label}</dt><dd>{value}</dd></div>)}</dl>
        <h3 className="mt-6 font-semibold">Status history</h3><ul>{detail.status_history.map(event => <li key={`${event.status}-${event.at}`}>{event.status} · {event.at}</li>)}</ul>
      </> : <p>Select a referral to see its summary and status history.</p>}
    </aside></div><footer className="text-sm text-neutral-600">Scaffold · status refreshes every 3 seconds · clinical triage is not implemented</footer>
  </main>;
}
