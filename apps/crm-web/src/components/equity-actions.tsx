"use client";
import { useState } from "react";
import { actionIDs, buildAction, evidence, rate, type ActionID, type Scenario } from "../lib/equity-actions";

export function EquityActions() {
  const [scenario, setScenario] = useState<Scenario>("baseline");
  return <section className="equity-section" id="equity-actions" aria-labelledby="equity-title">
    <div className="equity-heading">
      <div><p className="eyebrow">FROM EVIDENCE TO ACTION</p><h2 id="equity-title">What should we do?</h2><p>Find the handoff. Choose an owner. Test an improvement.</p></div>
      <label className="equity-scenario">Explore a scenario<select value={scenario} onChange={event => setScenario(event.target.value as Scenario)}>
        <option value="baseline">Illustrative gaps</option><option value="improved">Illustrative gaps closed</option>
      </select></label>
    </div>
    <div className="equity-disclosure"><strong>Synthetic scenario · not observed CRM data</strong><p>Fictional aggregate counts for an illustrative 12-week cohort. Screening, acknowledgment and attendance events are not collected by this CRM yet. Open or used referrals are not proxies for these measures. Scenarios are not forecasts.</p></div>
    <details className="equity-context"><summary>Finland: strategy alignment &amp; what the data can tell us</summary>
      <div className="equity-context-grid"><div><h3>Anchor to Goal 3</h3><p>Equal and effective cancer care needs an outcome measure, such as cancer mortality or survival, alongside pathway measures. These cards propose service-process pilots; they do not demonstrate an improvement in survival. Screening supports prevention and detection, but is not sufficient alone to demonstrate Goal 3.</p></div>
      <div><h3>Keep the missing middle visible</h3><p>Public screening and outcome statistics can inform a regional brief. General specialist waiting lists are not cancer-specific symptom-to-treatment delays. Acknowledgment and attendance measures need a locally agreed event-data pilot; do not infer them from registry outcomes.</p></div></div>
      <p>Before using real county comparisons: align year, cancer type, age standardisation, cohort definitions and denominators. Select the exact strategy indicator and confirm evidence with an AstraZeneca mentor.</p>
      <div className="equity-source-links"><a href="https://tilastot.syoparekisteri.fi/" target="_blank" rel="noreferrer">Finnish Cancer Registry statistics ↗</a><a href="https://sotkanet.fi/" target="_blank" rel="noreferrer">THL Sotkanet indicators ↗</a><a href="https://stat.fi/en/statistics/ksyyt" target="_blank" rel="noreferrer">Statistics Finland: causes of death ↗</a></div>
      <p className="equity-method">Source discovery informed by the team’s shared research discussion. No figures from that discussion have been treated as verified findings or imported into these scenarios.</p>
    </details>
    <div className="equity-grid">
      {actionIDs.map(id => <ActionCard key={`${id}-${scenario}`} id={id} scenario={scenario} />)}
    </div>
    <p className="equity-method">Method: comparison rate minus cohort rate, in percentage points. Counts and calculations are deterministic; AI only explains a reviewed plan. These examples do not establish causation or national disparities. Goal 3 indicator mapping and local feasibility need mentor and regional review.</p>
  </section>;
}

function ActionCard({ id, scenario }: { id: ActionID; scenario: Scenario }) {
  const plan = buildAction(id, scenario);
  const source = evidence[plan.source];
  const [explanation, setExplanation] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  async function explain() {
    setBusy(true); setError("");
    try {
      const response = await fetch("/demo/equity/explain", { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ id, scenario }), signal: AbortSignal.timeout(35000) });
      if (!response.ok) throw new Error("AI explanation unavailable. The reviewed plan remains available below.");
      const result = await response.json() as { explanation: string };
      setExplanation(result.explanation);
    } catch { setError("AI explanation unavailable. The reviewed plan remains available below."); }
    finally { setBusy(false); }
  }
  return <article className="equity-card" aria-labelledby={`action-${id}`}>
    <div className="equity-card-header"><span className="equity-stage">{plan.stage}</span><span className={`equity-status ${plan.detected ? "" : "closed"}`}>{plan.detected ? "Scenario gap" : "No gap detected"}</span></div>
    <h3 id={`action-${id}`}>{plan.title}</h3>
    <div className="equity-gap"><strong>{Math.max(0, plan.gap).toFixed(1)}<span> pp</span></strong><span>{id === "acknowledgment" ? "below proposed target" : id === "screening" ? "screening participation gap" : "appointment attendance gap"}</span></div>
    <dl className="equity-counts">{([plan.a, plan.b] as const).map((counts, index) => <div key={index}>
      <dt>{plan.labels[index]}</dt><dd>{counts[0]} / {counts[1]} <strong>{rate(...counts)!.toFixed(0)}%</strong></dd>
    </div>)}</dl>
    {!plan.detected ? <p className="equity-no-gap">No additional action triggered by this scenario. Continue monitoring; this does not establish equity across other groups or stages.</p> : <>
      <h4>Recommended action</h4><p>{plan.action}</p>
      <div className="equity-owner"><span>Accountable owner</span><strong>{plan.owner}</strong></div>
      <details><summary>Why this fits &amp; implementation plan</summary>
        <h4>Why this gap?</h4><p>{plan.why}</p>
        <h4>Implementation steps</h4><ol>{plan.steps.map(step => <li key={step}>{step}</li>)}</ol>
        <h4>Resources to agree locally</h4><p>{plan.resources}</p>
        <h4>Measure</h4><p>{plan.measure}</p>
      </details>
      <div className="equity-target"><span>PILOT TARGET · NOT A PREDICTED EFFECT</span><p>{plan.target}</p></div>
      <div className="equity-evidence"><h4>Evidence behind the action</h4><a href={source.url} target="_blank" rel="noreferrer">{source.title} ↗</a>
        <p>{source.publisher} · Published <time dateTime={source.published}>{source.published}</time></p>
        <details><summary>Evidence &amp; limits</summary><p>{source.summary}</p><p>{source.limitation}</p><p>Reviewed evidence snapshot. Not a live literature review.</p></details>
      </div>
      <button className="secondary-button equity-explain" onClick={() => void explain()} disabled={busy || Boolean(explanation)}>{busy ? "Preparing explanation…" : explanation ? "Explanation ready" : "Explain this plan with AI"}</button>
      <div aria-live="polite">{error ? <p className="equity-ai-error" role="alert">{error}</p> : null}
        {explanation ? <div className="equity-ai"><h4>AI-assisted explanation · review required</h4><p>{explanation}</p><small>Grounded in the evidence linked above. AI text may be inaccurate; it does not change the calculation, action or pilot target.</small></div> : null}</div>
    </>}
  </article>;
}
