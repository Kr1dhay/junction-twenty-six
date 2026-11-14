"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import { Edi } from "./edi";

export function DemoEntry() {
  const router = useRouter();
  const [attempt, setAttempt] = useState(0);
  const [error, setError] = useState("");

  useEffect(() => {
    const controller = new AbortController();
    let cancelled = false;
    const timeout = setTimeout(() => controller.abort(), 15_000);
    async function enter() {
      try {
        const response = await fetch("/demo/session", { method: "POST", signal: controller.signal });
        if (!response.ok) throw new Error("The demo workspace is unavailable. Please try again.");
        if (!cancelled) router.refresh();
      } catch {
        if (!cancelled) setError("Unable to open the demo workspace. Check your connection and try again.");
      } finally { clearTimeout(timeout); }
    }
    void enter();
    return () => { cancelled = true; clearTimeout(timeout); controller.abort(); };
  }, [attempt, router]);

  return <main className="login-page"><div className="login-card">
    <div className="login-brand"><Edi /><span>Edge-Care</span></div>
    <p className="eyebrow">EDGE-CARE / CLINICIAN WORKSPACE</p>
    <h1>Care begins<br />with connection.</h1>
    {error ? <><p className="error-banner" role="alert">{error}</p><button className="primary-button" onClick={() => { setError(""); setAttempt(value => value + 1); }}>Try again</button></> : <p role="status">Opening clinician workspace…</p>}
    <noscript><p>Enable JavaScript to open the clinician workspace.</p></noscript>
    <p className="login-disclaimer">Demonstration only. Do not enter real patient data.</p>
  </div></main>;
}
