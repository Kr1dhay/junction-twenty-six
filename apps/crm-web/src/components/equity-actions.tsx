"use client";
import { useEffect, useState } from "react";
import type { CRMReferral } from "@edgecare/shared-types";
import { actionsFor, briefText, buildBrief, evidence, type Action } from "../lib/equity-actions";
import { buildPathway, flagThreshold, invitationRound, measureSpec, projectedParticipation, rankCounties, screeningTarget,
  snapshot, stages, type CountyPathway, type Measure, type PathwayData, type StageResult } from "../lib/pathway";
import { formatWait, reviewAfterDays, waitingSummary } from "../lib/waiting";
import styles from "./equity-visuals.module.css";

const percent = (value: number) => `${Number.isInteger(value) ? value : value.toFixed(1)}%`;
const points = (value: number) => `${Math.abs(value).toFixed(1)} pp`;
const day = (value: string) => new Intl.DateTimeFormat("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" }).format(new Date(value));
const clock = (value: string) => new Intl.DateTimeFormat("en-GB", { hour: "2-digit", minute: "2-digit", timeZone: "UTC" }).format(new Date(value));
const gapText = (gap: number) => gap > 0 ? `${points(gap)} behind Finland` : gap < 0 ? `${points(gap)} ahead of Finland` : "level with Finland";
const defaultRegion = snapshot.regions.find(region => region.name === "Helsinki") ?? snapshot.regions[0]!;

function stageStatus(stage: StageResult, furthest: boolean) {
  if (!stage.worst) return "No public data";
  if (furthest) return "Furthest behind";
  if (stage.behind) return "Behind Finland";
  return stage.worst.gap! <= 0 ? "Level or ahead" : "Close to Finland";
}

export function EquityActions({ standalone = false }: { standalone?: boolean }) {
  const [data, setData] = useState<PathwayData>(snapshot);
  const [regionID, setRegionID] = useState(defaultRegion.id);
  const [indicatorID, setIndicatorID] = useState(stages[0]!.measures[1]!.id);
  const Heading = standalone ? "h1" : "h2";
  useEffect(() => {
    const code = new URLSearchParams(window.location.search).get("county");
    const match = snapshot.regions.find(region => region.code === code);
    if (match) setRegionID(match.id);
    const controller = new AbortController();
    // The committed snapshot renders immediately; a successful refresh replaces it.
    fetch("/demo/equity/data", { cache: "no-store", signal: controller.signal })
      .then(response => response.ok ? response.json() as Promise<PathwayData> : undefined)
      .then(fresh => { if (fresh?.indicators && fresh.regions?.length) setData(fresh); })
      .catch(() => undefined);
    return () => controller.abort();
  }, []);
  function choose(id: number) {
    setRegionID(id);
    const region = data.regions.find(item => item.id === id);
    if (region) window.history.replaceState(null, "", `?county=${region.code}`);
  }
  const pathway = buildPathway(data, regionID) ?? buildPathway(data, data.regions[0]!.id)!;
  const actions = actionsFor(pathway);
  const years = [...new Set(Object.values(data.indicators).map(indicator => indicator.year))].sort();
  const publishers = [...new Set(Object.values(data.indicators).map(indicator => indicator.organization))].sort();
  return <section className="equity-section" id="equity-actions" aria-labelledby="equity-title">
    <div className="equity-heading">
      <div><p className="eyebrow">FROM PUBLIC DATA TO ACTION</p><Heading id="equity-title">What should we do?</Heading><p>Pick a county. See where it falls behind. Choose the action.</p></div>
      <label className="equity-scenario">County<select value={pathway.region.id} onChange={event => choose(Number(event.target.value))}>
        {data.regions.map(region => <option key={region.id} value={region.id}>{region.name}</option>)}
      </select></label>
    </div>
    <div className="equity-disclosure"><strong>Public county data · {data.source}</strong><p>Published by {publishers.join(" and ")}; latest year available for each measure ({years.join("–")}). {data.live ? `Refreshed from Sotkanet on ${day(data.generated_at)} at ${clock(data.generated_at)} UTC.` : `Saved copy from ${day(data.generated_at)}.`} These are county averages. They do not describe individuals, and they cannot show differences between groups inside a county.</p></div>
    <CountyBrief key={`${pathway.region.id}-${data.generated_at}`} pathway={pathway} basis={data.live ? "live" : "snapshot"} />
    <PathwayOverview pathway={pathway} />
    <WorkspaceTiming />
    <CountyRanking data={data} indicatorID={indicatorID} onIndicator={setIndicatorID} selected={pathway.region.id} onSelect={choose} />
    <details className="equity-context"><summary>Finland: strategy alignment &amp; what the data can tell us</summary>
      <div className="equity-context-grid"><div><h3>Anchor to Goal 3</h3><p>The National Cancer Strategy 2026–2035 measures “equal and effective cancer care” by five-year survival, cancer mortality and access to treatment within target times, and asks that regional and socioeconomic differences be known and used in decisions. Survival is the Goal 3 measure shown here; screening, primary care access and referral handling show where an earlier stage may contribute.</p></div>
      <div><h3>Keep the missing middle visible</h3><p>Public data has no cancer-specific county figure for the time from referral to diagnosis or treatment. Referral handling here covers all specialties, and the barrier survey covers all health services. Timing referrals locally is the only way to see that stage.</p></div></div>
      <p>Before acting on a county comparison: check the year, the cancer type, case numbers and age structure, and confirm the reading with regional clinicians. A lower rank is a prompt to look, not proof of worse care.</p>
      <div className="equity-source-links"><a href={data.source_url} target="_blank" rel="noreferrer">THL Sotkanet indicators ↗</a><a href="https://tilastot.syoparekisteri.fi/" target="_blank" rel="noreferrer">Finnish Cancer Registry statistics ↗</a><a href={evidence.strategy.url} target="_blank" rel="noreferrer">National Cancer Strategy 2026–2035 ↗</a></div>
    </details>
    {actions.length ? <div className="equity-grid">{actions.map(action => <ActionCard key={`${pathway.region.id}-${action.id}`} action={action} pathway={pathway} data={data} />)}</div>
      : <p className="equity-no-gap">No action plan is triggered: {pathway.region.name} is not {flagThreshold} percentage point or more behind Finland on any measure with public data.</p>}
    <p className="equity-method">Method: each measure compares the county with the national figure in percentage points and ranks it among counties that publish the measure. A stage is flagged when any of its measures is at least {flagThreshold} percentage point behind Finland; the stage with the weakest average rank is marked furthest behind. Calculations are deterministic. AI only rewords the brief and may not add numbers.</p>
  </section>;
}

function CountyBrief({ pathway, basis }: { pathway: CountyPathway; basis: "live" | "snapshot" }) {
  const brief = buildBrief(pathway);
  const [explanation, setExplanation] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const [canSpeak, setCanSpeak] = useState(false);
  const [speaking, setSpeaking] = useState(false);
  useEffect(() => {
    setCanSpeak("speechSynthesis" in window);
    return () => { if ("speechSynthesis" in window) window.speechSynthesis.cancel(); };
  }, []);
  const spoken = [`${brief.county}.`, briefText(brief), explanation].filter(Boolean).join(" ");
  const seconds = Math.max(10, Math.round(spoken.split(/\s+/).length / 150 * 60 / 5) * 5);
  function read() {
    window.speechSynthesis.cancel();
    if (speaking) { setSpeaking(false); return; }
    const utterance = new SpeechSynthesisUtterance(spoken);
    utterance.lang = "en-GB"; utterance.onend = () => setSpeaking(false); utterance.onerror = () => setSpeaking(false);
    setSpeaking(true); window.speechSynthesis.speak(utterance);
  }
  async function explain() {
    setBusy(true); setError("");
    try {
      const response = await fetch("/demo/equity/explain", { method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ region: pathway.region.id, basis }), signal: AbortSignal.timeout(35000) });
      if (!response.ok) throw new Error("unavailable");
      setExplanation((await response.json() as { explanation: string }).explanation);
    } catch { setError("AI explanation unavailable. The data-based brief above is unaffected."); }
    finally { setBusy(false); }
  }
  return <section className={styles.brief} aria-labelledby="brief-title">
    <div className={styles.briefHeading}><div><p className="eyebrow">TWO-MINUTE BRIEF</p><h3 id="brief-title">{brief.county}: the gap, where it opens, what to do</h3></div>
      <p className={styles.briefTime}>About {seconds} seconds read aloud</p></div>
    <ol className={styles.briefSteps}>
      <li><span>The gap</span><p>{brief.gap}</p></li>
      <li><span>Where it opens</span><p>{brief.where}</p></li>
      <li><span>What to do</span><p>{brief.action}</p></li>
    </ol>
    {pathway.smallPopulation ? <p className={styles.caution}>Small population: yearly survival figures for {brief.county} rest on few cases and can move several points between years.</p> : null}
    <div className={styles.briefActions}>
      {canSpeak ? <button className="secondary-button" onClick={read} aria-pressed={speaking}>{speaking ? "Stop reading" : "Read aloud"}</button> : null}
      {brief.evidence ? <button className="secondary-button" onClick={() => void explain()} disabled={busy || Boolean(explanation)}>{busy ? "Preparing explanation…" : explanation ? "Explanation ready" : "Explain with AI"}</button> : null}
    </div>
    <div aria-live="polite">{error ? <p className="equity-ai-error" role="alert">{error}</p> : null}
      {explanation ? <div className="equity-ai"><h4>AI-assisted explanation · review required</h4><p>{explanation}</p><small>Uses only the figures and evidence shown on this page. AI text may be inaccurate; it does not change any number, action or target.</small></div> : null}</div>
  </section>;
}

function PathwayOverview({ pathway }: { pathway: CountyPathway }) {
  const behind = pathway.stages.filter(stage => stage.behind);
  return <section className={styles.overview} aria-labelledby="pathway-title">
    <div className={styles.overviewHeading}>
      <div><p className="eyebrow">PATHWAY AT A GLANCE</p><h3 id="pathway-title">Where does {pathway.region.name} fall behind?</h3></div>
      <p className={styles.summary} role="status"><strong>{behind.length} / {pathway.stages.length}</strong> stages behind Finland</p>
    </div>
    <ol className={styles.pathway}>
      {pathway.stages.map((stage, index) => {
        const furthest = stage.id === pathway.furthest, status = stageStatus(stage, furthest);
        const body = <>
          <span className={styles.stageTop}><span className={styles.step}>{String(index + 1).padStart(2, "0")}</span><span className={styles.stageStatus}>{status}</span></span>
          <span className={styles.stageName}>{stage.name}</span>
          {stage.worst ? <span className={styles.stageMetric}><strong>{percent(stage.worst.value!)}</strong><span>{stage.worst.spec.label} · {gapText(stage.worst.gap!)}</span></span>
            : <span className={styles.stageMetric}><span>No county figure is published for this stage.</span></span>}
          <span className={styles.stageAction}>{stage.behind ? <>View action plan <span aria-hidden="true">→</span></> : "No action triggered"}</span>
        </>;
        return <li key={stage.id} className={furthest ? styles.furthest : stage.behind ? styles.behind : undefined}>
          {stage.behind ? <a href={`#plan-${stage.id}`} className={styles.stageLink}>{body}</a> : <div className={styles.stageLink}>{body}</div>}
        </li>;
      })}
    </ol>
    <p className={styles.overviewNote}>pp = percentage points. Each stage uses its own population and year; this is not a patient funnel. Between referral handling and survival, no cancer-specific county figure is public.</p>
  </section>;
}

/** The stage public data cannot see: how long this workspace's own referrals wait. One read, no polling. */
function WorkspaceTiming() {
  const [summary, setSummary] = useState<ReturnType<typeof waitingSummary>>();
  useEffect(() => {
    const controller = new AbortController();
    fetch("/referrals", { cache: "no-store", signal: controller.signal })
      .then(response => response.ok ? response.json() as Promise<{ referrals: CRMReferral[] }> : undefined)
      .then(result => { if (result) setSummary(waitingSummary(result.referrals, Date.now())); })
      .catch(() => undefined);
    return () => controller.abort();
  }, []);
  if (!summary) return null;
  return <aside className={styles.timing} aria-label="Referral timing in this workspace">
    <div><p className="eyebrow">THE UNMEASURED STAGE</p><p>This workspace times its own referrals from receipt to verification by a clinician.</p></div>
    <dl>
      <div><dt>Open referrals</dt><dd>{summary.open}</dd></div>
      <div><dt>Longest open wait</dt><dd>{summary.longestOpen === null ? "–" : formatWait(summary.longestOpen)}</dd></div>
      <div><dt>Open over {reviewAfterDays} days</dt><dd>{summary.overdue}</dd></div>
      <div><dt>Median time to verification</dt><dd>{summary.medianToVerified === null ? "–" : formatWait(summary.medianToVerified)}</dd></div>
    </dl>
    <small>Synthetic demo referrals, not county data. <a href="/">Open the referral list</a></small>
  </aside>;
}

function CountyRanking({ data, indicatorID, onIndicator, selected, onSelect }: {
  data: PathwayData; indicatorID: number; onIndicator: (id: number) => void; selected: number; onSelect: (id: number) => void;
}) {
  const indicator = data.indicators[indicatorID], spec = measureSpec(indicatorID);
  if (!indicator || !spec) return null;
  const rows = rankCounties(data, indicatorID);
  const values = rows.flatMap(row => row.value === null ? [] : [row.value]).concat(indicator.national.value, spec.target ?? indicator.national.value);
  const low = Math.max(0, Math.floor(Math.min(...values) / 5) * 5 - 5), high = Math.min(100, Math.ceil(Math.max(...values) / 5) * 5 + 5);
  const position = (value: number) => `${(value - low) / (high - low) * 100}%`;
  return <section className={styles.ranking} aria-labelledby="ranking-title">
    <div className={styles.rankingHeading}>
      <div><p className="eyebrow">ALL COUNTIES</p><h3 id="ranking-title">How every county compares</h3></div>
      <label className="equity-scenario">Measure<select value={indicatorID} onChange={event => onIndicator(Number(event.target.value))}>
        {stages.map(stage => <optgroup key={stage.id} label={stage.name}>{stage.measures.map(measure => <option key={measure.id} value={measure.id}>{measure.label}</option>)}</optgroup>)}
      </select></label>
    </div>
    <p className={styles.rankingNote}>{indicator.title} · {indicator.organization}, {indicator.year}. {spec.better === "higher" ? "Higher is better" : "Lower is better"}; best county first. Select a county to brief it.</p>
    <div className={styles.legend} aria-hidden="true"><span className={styles.legendNational}>Finland {percent(indicator.national.value)}</span>{spec.target !== undefined ? <span className={styles.legendTarget}>Strategy target {percent(spec.target)}</span> : null}<span className={styles.legendAxis}>Axis {low}%–{high}%</span></div>
    <ol className={styles.rankList}>{rows.map(row => <li key={row.region.id}>
      <button className={styles.rankRow} onClick={() => onSelect(row.region.id)} aria-pressed={row.region.id === selected}
        title={row.value === null ? `${row.region.name}: no figure published` : `${row.region.name}: ${percent(row.value)}, ${gapText(row.gap!)}`}>
        <span className={styles.rankNumber}>{row.rank ?? "–"}</span>
        <span className={styles.rankName}>{row.region.name}</span>
        <span className={styles.rankTrack} aria-hidden="true">
          <i className={styles.nationalLine} style={{ left: position(indicator.national.value) }} />
          {spec.target !== undefined ? <i className={styles.targetLine} style={{ left: position(spec.target) }} /> : null}
          {row.value !== null ? <i className={styles.dot} style={{ left: position(row.value) }} /> : null}
        </span>
        <span className={styles.rankValue}>{row.value === null ? "No data" : `${row.value.toFixed(1)}%`}</span>
      </button>
    </li>)}</ol>
  </section>;
}

function MeasureComparison({ action, county }: { action: Action; county: string }) {
  return <figure className={styles.comparison} aria-labelledby={`comparison-${action.id}`}>
    <figcaption id={`comparison-${action.id}`}>{county} compared with Finland <span>Share of the measured population · 0–100%</span></figcaption>
    <dl className={styles.rates}>{action.measures.map(measure => <div key={measure.spec.id}>
      <dt>{measure.spec.label}<span>{measure.organization}, {measure.year}{measure.spec.better === "lower" ? " · lower is better" : ""}</span></dt>
      {measure.value === null ? <dd className={styles.noData}>No county figure published.</dd> : <dd>
        <Bar label={county} value={measure.value} target={measure.spec.target} />
        <Bar label="Finland" value={measure.national} target={measure.spec.target} reference />
        <p className={styles.rankLine}>{gapText(measure.gap!)} · rank {measure.rank} of {measure.of}{measure.targetGap !== null && measure.targetGap > 0 ? ` · ${points(measure.targetGap)} below the ${screeningTarget}% target` : ""}</p>
      </dd>}
    </div>)}</dl>
  </figure>;
}
function Bar({ label, value, target, reference = false }: { label: string; value: number; target?: number; reference?: boolean }) {
  return <div className={reference ? styles.reference : styles.cohort}>
    <div className={styles.rateValue}><span>{label}</span><strong>{percent(value)}</strong></div>
    <div className={styles.track} aria-hidden="true"><span style={{ width: `${value}%` }} />{target !== undefined ? <i className={styles.targetTick} style={{ left: `${target}%` }} /> : null}</div>
  </div>;
}

function ScreeningTarget({ action, data, pathway }: { action: Action; data: PathwayData; pathway: CountyPathway }) {
  const programmes = action.measures.filter(measure => measure.value !== null && invitationRound(data.indicators[measure.spec.id]?.values[pathway.region.id]));
  const lowest = programmes.reduce<Measure | undefined>((current, measure) => !current || measure.value! < current.value! ? measure : current, undefined);
  const [programmeID, setProgrammeID] = useState(lowest?.spec.id);
  const [share, setShare] = useState(0);
  const measure = programmes.find(item => item.spec.id === programmeID) ?? lowest;
  const round = measure && invitationRound(data.indicators[measure.spec.id]?.values[pathway.region.id]);
  if (!measure || !round) return null;
  const result = projectedParticipation(round, share / 100);
  const reached = result.rate >= screeningTarget;
  return <div className={styles.slider}>
    <h4>What would reach the {screeningTarget}% target?</h4>
    <label className={styles.sliderField}>Programme<select value={measure.spec.id} onChange={event => { setProgrammeID(Number(event.target.value)); setShare(0); }}>
      {programmes.map(item => <option key={item.spec.id} value={item.spec.id}>{item.spec.label.replace(" participation", "")}</option>)}
    </select></label>
    <p>About {round.invited.toLocaleString("en-GB")} people were invited in {measure.year} and {round.attended.toLocaleString("en-GB")} attended. {round.needed > 0
      ? <><strong>{round.needed.toLocaleString("en-GB")} more attendances</strong> would reach {screeningTarget}%.</> : <>That is already at or above {screeningTarget}%.</>}</p>
    <label className={styles.sliderField} htmlFor={`share-${action.id}`}>If this share of the people who did not attend took part</label>
    <div className={styles.sliderRow}><input id={`share-${action.id}`} type="range" min={0} max={50} step={1} value={share} aria-valuetext={`${share}% of people who did not attend`} onChange={event => setShare(Number(event.target.value))} /><span className={styles.sliderShare} aria-hidden="true">{share}%</span></div>
    <div className={styles.track} aria-hidden="true"><span style={{ width: `${result.rate}%` }} /><i className={styles.targetTick} style={{ left: `${screeningTarget}%` }} /></div>
    <p className={styles.sliderResult} role="status">Participation {percent(result.rate)} · {result.extra.toLocaleString("en-GB")} more people · {reached ? `reaches the ${screeningTarget}% target` : `still below the ${screeningTarget}% target`}</p>
    <small>Arithmetic on the {measure.year} invitation round; invited is estimated from the published count and rate. This is not a forecast of what an action achieves.</small>
  </div>;
}

function ActionCard({ action, pathway, data }: { action: Action; pathway: CountyPathway; data: PathwayData }) {
  const source = evidence[action.source], furthest = action.id === pathway.furthest;
  return <article className={`equity-card ${styles.card}`} id={`plan-${action.id}`} tabIndex={-1} aria-labelledby={`action-${action.id}`}>
    <div className="equity-card-header"><span className="equity-stage">{action.stage}</span><span className="equity-status">{furthest ? "Furthest behind" : "Behind Finland"}</span></div>
    <h3 id={`action-${action.id}`}>{action.title}</h3>
    <div className="equity-gap"><strong>{action.gap.toFixed(1)}<span> pp</span></strong><span>behind Finland · {action.worst?.spec.label}</span></div>
    <MeasureComparison action={action} county={pathway.region.name} />
    {action.id === "screening" ? <ScreeningTarget action={action} data={data} pathway={pathway} /> : null}
    <h4>Recommended action</h4><p>{action.action}</p>
    <div className="equity-owner"><span>Accountable owner</span><strong>{action.owner}</strong></div>
    <details><summary>Why this fits &amp; implementation plan</summary>
      <h4>Why this gap?</h4><p>{action.why}</p>
      <h4>Implementation steps</h4><ol>{action.steps.map(step => <li key={step}>{step}</li>)}</ol>
      <h4>Resources to agree locally</h4><p>{action.resources}</p>
      <h4>Measure</h4><p>{action.measure}</p>
    </details>
    <div className="equity-target"><span>PILOT TARGET · NOT A PREDICTED EFFECT</span><p>{action.target}</p></div>
    <div className="equity-evidence"><h4>Evidence behind the action</h4><a href={source.url} target="_blank" rel="noreferrer">{source.title} ↗</a>
      <p>{source.publisher} · Published <time dateTime={source.published}>{source.published}</time></p>
      <details><summary>Evidence &amp; limits</summary><p>{source.summary}</p><p>{source.limitation}</p><p>Reviewed evidence snapshot. Not a live literature review.</p></details>
    </div>
  </article>;
}
