"use client";
import { ReferralAppointment } from "./referral-appointment";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import type { CRMReferral } from "@edgecare/shared-types";
import { EquityActions } from "./equity-actions";

const languages: Record<string, string> = { en: "English", fi: "Finnish", so: "Somali", ar: "Arabic", ru: "Russian", ku: "Kurdish" };
const statusLabels = { open: "Awaiting verification", spent: "Verified · used", expired: "Expired" };
const date = (value: string) => new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }).format(new Date(value));
const time = (value: string) => new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: "UTC" }).format(new Date(value));
const title = (value: string) => value.charAt(0).toUpperCase() + value.slice(1);
function Icon({ kind }: { kind: "grid" | "shield" | "arrow" | "refresh" | "search" }) {
  return <svg aria-hidden="true" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">{kind === "grid" ? <><rect x="3" y="3" width="7" height="7" rx="1.5" /><rect x="14" y="3" width="7" height="7" rx="1.5" /><rect x="3" y="14" width="7" height="7" rx="1.5" /><rect x="14" y="14" width="7" height="7" rx="1.5" /></> : kind === "shield" ? <><path d="M12 3 4 6v6c0 5 8 9 8 9s8-4 8-9V6z" /><path d="m8 12 3 3 5-6" /></> : kind === "refresh" ? <><path d="M20 7v5h-5M4 17v-5h5" /><path d="M6 7a7 7 0 0 1 12-1l2 3M4 15l2 3a7 7 0 0 0 12-1" /></> : kind === "search" ? <><circle cx="10" cy="10" r="6" /><path d="m15 15 5 5" /></> : <path d="m9 5 7 7-7 7" />}</svg>;
}

export function ReferralDashboard({ view = "referrals" }: { view?: "referrals" | "equity" }) {
  const router = useRouter();
  const [referrals, setReferrals] = useState<CRMReferral[]>([]);
  const [selected, setSelected] = useState<string>();
  const [error, setError] = useState("");
  const [loaded, setLoaded] = useState(false);
  const [lastSync, setLastSync] = useState("");
  const [refreshKey, setRefreshKey] = useState(0);
  const [status, setStatus] = useState("");
  const [risk, setRisk] = useState("");
  const [specialty, setSpecialty] = useState("");
  const [search, setSearch] = useState("");
  const [from, setFrom] = useState("");
  const [to, setTo] = useState("");
  const [sort, setSort] = useState("newest");
  useEffect(() => {
    if (view === "equity") return;
    const controller = new AbortController();
    let running = false;
    async function refresh() {
      if (running || document.hidden) return;
      running = true;
      try {
        const response = await fetch("/referrals", { cache: "no-store", signal: controller.signal });
        if (response.status === 401) { router.refresh(); return; }
        if (!response.ok) throw new Error("Unable to reach the local registry. Showing the last received records; status may have changed.");
        const data = await response.json() as { referrals: CRMReferral[] };
        setReferrals(data.referrals); setError(""); setLoaded(true); setLastSync(new Date().toISOString());
      } catch (cause) {
        if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : "Connection unavailable");
      } finally { running = false; }
    }
    void refresh();
    const timer = setInterval(() => void refresh(), 2000);
    const onVisible = () => void refresh();
    document.addEventListener("visibilitychange", onVisible);
    return () => { controller.abort(); clearInterval(timer); document.removeEventListener("visibilitychange", onVisible); };
  }, [refreshKey, router, view]);
  const invalidDates = Boolean(from && to && from > to);
  const visible = referrals.filter(record => (!status || record.status === status) && (!risk || record.risk_band === risk)
    && (!specialty || record.recommended_specialty === specialty) && (!from || record.created_at.slice(0, 10) >= from)
    && (!to || record.created_at.slice(0, 10) <= to) && (!search || `${record.referral_id} ${record.free_text_summary} ${record.recommended_specialty} ${languages[record.language] ?? record.language}`.toLowerCase().includes(search.toLowerCase())))
    .sort((a, b) => sort === "risk" ? b.risk_score - a.risk_score : b.created_at.localeCompare(a.created_at));
  const detail = visible.find(record => record.referral_id === selected) ?? visible[0];
  const activeFilters = Boolean(risk || specialty || from || to || search);
  const reset = () => { setRisk(""); setSpecialty(""); setFrom(""); setTo(""); setSearch(""); setStatus(""); };
  return <div className="workspace">
    <a className="skip-link" href="#workspace-content">Skip to main content</a>
    <aside className="sidebar" aria-label="Workspace navigation">
      <a className="wordmark" href="/"><span className="brand-mark" aria-hidden="true">e<span>·</span></span>edge-care</a>
      <div className="workspace-label">CLINICAL WORKSPACE</div>
      {view === "equity" ? <nav aria-label="Referrals"><a className="nav-item" href="/"><Icon kind="grid" />All referrals</a></nav> : <nav aria-label="Referral status"><button className={`nav-item ${status === "" ? "active" : ""}`} onClick={() => setStatus("")} aria-current={status === "" ? "page" : undefined}><Icon kind="grid" />All referrals<span>{referrals.length}</span></button>
        {(["open", "spent", "expired"] as const).map(value => <button key={value} className={`nav-item ${status === value ? "active" : ""}`} onClick={() => setStatus(value)} aria-current={status === value ? "page" : undefined}><i className={`status-dot ${value}`} aria-hidden="true" />{value === "open" ? "Awaiting verification" : value === "spent" ? "Verified referrals" : "Expired"}<span>{referrals.filter(record => record.status === value).length}</span></button>)}
      </nav>}
      <a className={`nav-item equity-nav ${view === "equity" ? "active" : ""}`} href="/equity-actions" aria-label="Equity actions" title="Equity actions" aria-current={view === "equity" ? "page" : undefined}><Icon kind="grid" />Equity actions</a>
      <div className="sidebar-note"><Icon kind="shield" /><strong>Anonymous by design</strong><p>No names. No contact details. Only what is needed to continue care.</p></div>
      <div className="session"><div className="avatar" aria-hidden="true">EC</div><div><strong>Demo clinician</strong><small>Synthetic workspace</small></div></div>
    </aside>
    <div className="workspace-body">
      <header className="topbar"><span>Workspace <span aria-hidden="true">/</span> <strong>{view === "equity" ? "Equity actions" : "Referrals"}</strong></span><span className="demo-tag">SYNTHETIC DEMO</span></header>
      <nav className="mobile-workspace-nav" aria-label="Workspace pages">
        <a href="/" aria-current={view === "referrals" ? "page" : undefined}>All referrals</a>
        <a href="/equity-actions" aria-current={view === "equity" ? "page" : undefined}>Equity actions</a>
      </nav>
      <main id="workspace-content" className={`main-content ${view === "equity" ? "equity-page" : ""}`}>
        {view === "equity" ? <EquityActions standalone /> : <>
        <div className="page-heading"><div><p className="eyebrow">A CLEARER PATH TO CARE</p><h1>Anonymous referrals</h1><p>Every referral is a person’s next step.</p></div><button className="secondary-button refresh-button" onClick={() => setRefreshKey(value => value + 1)}><Icon kind="refresh" />Refresh</button></div>
        <div className="overview" aria-label="Referral overview"><div><span>Awaiting verification</span><strong>{referrals.filter(r => r.status === "open").length.toString().padStart(2, "0")}</strong><small>Ready for the next step</small></div><div><span>High priority · open</span><strong className="mulberry">{referrals.filter(r => r.status === "open" && r.risk_band === "high").length.toString().padStart(2, "0")}</strong><small>Review with clinical judgment</small></div><div><span>Verified referrals</span><strong>{referrals.filter(r => r.status === "spent").length.toString().padStart(2, "0")}</strong><small>Single-use commitment accepted</small></div><div className="sync-card"><span className={`sync-indicator ${error ? "offline" : ""}`} /><strong>{error ? "Connection interrupted" : loaded ? "Registry connected" : "Connecting to registry"}</strong><small>{lastSync ? `Updated ${time(lastSync)} UTC · every 2 seconds` : "Connecting to the local demo backend"}</small></div></div>
        <section className="filter-panel" aria-label="Filter referrals">
          <label className="search-field"><Icon kind="search" /><span className="sr-only">Search referrals</span><input type="search" placeholder="Search referral, specialty or summary" value={search} onChange={event => setSearch(event.target.value)} /></label>
          <div className="filters"><label>Status<select value={status} onChange={event => setStatus(event.target.value)}><option value="">All statuses</option><option value="open">Awaiting verification</option><option value="spent">Verified</option><option value="expired">Expired</option></select></label><label>Risk band<select value={risk} onChange={event => setRisk(event.target.value)}><option value="">All risk bands</option>{["high", "medium", "low"].map(value => <option key={value} value={value}>{title(value)}</option>)}</select></label><label>Specialty<select value={specialty} onChange={event => setSpecialty(event.target.value)}><option value="">All specialties</option>{[...new Set(referrals.map(record => record.recommended_specialty))].sort().map(value => <option key={value} value={value}>{title(value)}</option>)}</select></label><label>From · UTC<input type="date" value={from} max={to || undefined} onChange={event => setFrom(event.target.value)} /></label><label>To · UTC<input type="date" value={to} min={from || undefined} onChange={event => setTo(event.target.value)} /></label>{activeFilters ? <button className="text-button clear-filters" onClick={reset}>Clear filters</button> : null}</div>
          {invalidDates ? <p role="alert" className="field-error">Choose an end date on or after the start date.</p> : null}
        </section>
        {error ? <p className="error-banner" role="alert">{error}</p> : null}
        <div className="referral-workspace"><section className="referral-list" aria-label="Referrals"><div className="list-heading"><h2>{status ? title(status === "spent" ? "verified referrals" : `${status} referrals`) : "All referrals"}<span>{visible.length}</span></h2><label className="sort-select"><span className="sr-only">Sort referrals</span><select value={sort} onChange={event => setSort(event.target.value)}><option value="newest">Newest first</option><option value="risk">Highest risk first</option></select></label></div>
          {!loaded && !error ? <div role="status" className="empty-state">Loading anonymous referrals…</div> : null}
          {loaded && !visible.length ? <div className="empty-state"><Icon kind="grid" /><h3>No referrals here yet</h3><p>{activeFilters || status ? "Adjust your filters to find a referral." : "New referrals appear here when a device syncs."}</p>{activeFilters || status ? <button className="secondary-button" onClick={reset}>Clear all filters</button> : null}</div> : null}
          {visible.map(record => <button key={record.referral_id} onClick={() => setSelected(record.referral_id)} aria-pressed={detail?.referral_id === record.referral_id} className={`referral-row ${detail?.referral_id === record.referral_id ? "selected" : ""}`}>
            <span className="row-top"><span className="referral-id">EC–{record.referral_id.slice(-8).toUpperCase()}</span><span className={`risk-badge ${record.risk_band}`}>{title(record.risk_band)} risk</span></span><strong className="specialty-title">{title(record.recommended_specialty)}</strong><span className="row-summary">{record.free_text_summary}</span><span className="row-meta"><span>{languages[record.language] ?? record.language} <span aria-hidden="true">·</span> {date(record.created_at)}</span><span className={`status-label ${record.status}`}><i aria-hidden="true" />{statusLabels[record.status]}</span></span><span className="row-chevron"><Icon kind="arrow" /></span>
          </button>)}
        </section><aside className="detail-panel" aria-label="Selected referral details">{detail ? <ReferralDetail detail={detail} /> : <div className="empty-state"><Icon kind="shield" /><h2>A private path to care</h2><p>Select a referral to review its clinical summary and verification history.</p></div>}</aside></div>
        </>}
        <footer className="workspace-footer"><Icon kind="shield" /><span>Synthetic data only · Demo triage is unvalidated and requires clinician review.</span><span>Local demo registry · UTC</span></footer>
      </main>
    </div>
  </div>;
}

function ReferralDetail({ detail }: { detail: CRMReferral }) {
  return <><div className="detail-heading"><p className="eyebrow">REFERRAL OVERVIEW</p><h2>{title(detail.recommended_specialty)}</h2><span className={`status-label ${detail.status}`}><i aria-hidden="true" />{statusLabels[detail.status]}</span></div><div className="detail-content"><div className="detail-id"><span>Anonymous referral</span><code>{detail.referral_id}</code></div><div className="detail-facts"><div><span>Preferred language</span><strong>{languages[detail.language] ?? detail.language}</strong></div><div><span>Created</span><strong>{date(detail.created_at)}</strong></div></div>
    <section className="detail-section"><h3>Clinical summary</h3><p>{detail.free_text_summary}</p><div className={`risk-note ${detail.risk_band}`}><span className={`risk-badge ${detail.risk_band}`}>{title(detail.risk_band)} risk</span><strong>{detail.risk_score}<span>/100</span></strong><small>Unvalidated demo score. Use clinical judgment.</small></div></section>
    <ReferralAppointment referralID={detail.referral_id} />
    <section className="detail-section"><h3>Patient guidance</h3><p lang={detail.language} dir="auto">{detail.patient_language_summary}</p></section>
    <section className="detail-section"><h3>Supporting information</h3><details open={detail.letter_scan.present}><summary>Screening or referral letter <span>{detail.letter_scan.present ? "Available" : "Not provided"}</span></summary><p>{detail.letter_scan.extracted_text ?? "No letter text was included with this referral."}</p></details><details open={detail.lesion_photo.present}><summary>Skin observation <span>{detail.lesion_photo.present ? "Available" : "Not provided"}</span></summary><p>{detail.lesion_photo.assessment ?? "No skin assessment was included with this referral."}</p></details></section>
    <section className="detail-section"><h3>Status history</h3><ol className="timeline">{detail.status_history.map(event => <li key={`${event.status}-${event.at}`}><span className={`timeline-dot ${event.status}`} aria-hidden="true" /><div><strong>{event.status === "open" ? "Referral received" : event.status === "spent" ? "Verification accepted" : "Referral expired"}</strong><time dateTime={event.at}>{date(event.at)} · {time(event.at)} UTC</time><p>{event.status === "open" ? "Anonymous record added to the care pathway." : event.status === "spent" ? "Single-use commitment spent in the shared registry." : "This referral can no longer be verified."}</p></div></li>)}</ol><p className="expiry-note">{detail.status === "expired" ? "Expired" : "Expires"} {date(detail.expires_at)} · {time(detail.expires_at)} UTC</p></section>
    <div className="verification-note"><Icon kind="shield" /><p>{detail.status === "open" ? "Verify on the doctor’s device. The patient’s signature and passcode are checked there; this workspace updates when the registry accepts the spend." : detail.status === "spent" ? "This commitment has been used. A second verification cannot spend it again." : "An expired referral cannot be used for verification."}</p></div>
  </div></>;
}
