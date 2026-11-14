"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
export function DemoLogin({ requiresToken = false }: { requiresToken?: boolean }) {
  const router = useRouter();
  const [token, setToken] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  async function enter() {
    setBusy(true); setError("");
    try {
      const response = await fetch("/demo/session", { method: "POST", headers: requiresToken ? { authorization: `Bearer ${token}` } : undefined });
      if (response.status === 401) throw new Error("Enter the clinician demo token configured on this server.");
      if (!response.ok) throw new Error("The synthetic demo backend is unavailable. Check the local demo configuration.");
      router.refresh();
    } catch (cause) { setError(cause instanceof Error ? cause.message : "Unable to enter the workspace"); setBusy(false); }
  }
  return <main className="login-page"><div className="login-card">
    <div className="brand-mark" aria-hidden="true">e<span>·</span></div>
    <p className="eyebrow">EDGE-CARE / CLINICIAN WORKSPACE</p>
    <h1>Care begins<br />with connection.</h1>
    <p className="login-intro">A calm place to review anonymous referrals and follow each step toward care.</p>
    <div className="privacy-note"><strong>No identity. A clear path to care.</strong><p>Referrals carry a clinical summary and a single-use commitment. Patient signatures and passcodes stay off this screen.</p></div>
    {requiresToken ? <label className="token-field">Clinician demo token<input type="password" value={token} onChange={event => setToken(event.target.value)} autoComplete="current-password" /></label> : null}
    <button className="primary-button" disabled={busy} onClick={() => void enter()}>{busy ? "Opening workspace…" : "Enter clinician demo"}<span aria-hidden="true">↗</span></button>
    {error ? <p className="error-banner" role="alert">{error}</p> : null}
    <p className="login-disclaimer">Synthetic demonstration only. This session is a local demo role, not a verified clinical identity. Do not enter real patient data.</p>
  </div><div className="login-foot">EDGE-CARE <span>Anonymous by design. Human by nature.</span></div></main>;
}
