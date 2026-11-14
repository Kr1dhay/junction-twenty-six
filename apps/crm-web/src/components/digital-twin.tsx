"use client";
import "maplibre-gl/dist/maplibre-gl.css";
import { useEffect, useMemo, useRef, useState } from "react";
import type { GeoJSONSource, Map as MapLibreMap, StyleSpecification } from "maplibre-gl";
import snapshot from "../lib/twin-snapshot.json";
import { applyResource, closureImpact, defaultSettings, prepare, rank, resources, simulate, stationName, summary, week,
  type Prepared, type Ranked, type Resource, type Settings, type Simulation, type TwinData, type Week } from "../lib/twin";
import styles from "./digital-twin.module.css";

const data = snapshot as unknown as TwinData;
const DRAWS = 40, SEED = 2026;
const finland = { center: [25.6, 64.2] as [number, number], zoom: 4.6, pitch: 50, bearing: -8 };
const darkStyle = "https://tiles.openfreemap.org/styles/dark";
const blankStyle: StyleSpecification = { version: 8, sources: {}, layers: [{ id: "background", type: "background", paint: { "background-color": "#0c0c0c" } }] };
const fmt = new Intl.NumberFormat("en-GB");
const n0 = (value: number) => fmt.format(Math.round(value));
const reducedMotion = () => typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

type Lens = "travel" | "capacity" | "waits" | "language";
// Magenta always means "worse"; cyan marks language need, which is not a problem in itself.
const lenses: Record<Lens, { label: string; question: string; reading: string; stops: [number, string][]; ticks: string[] }> = {
  travel: { label: "Travel time", question: "How far is care?", reading: "Minutes by car to the nearest open health station. Brighter magenta is further.",
    stops: [[5, "#3b2733"], [15, "#6b2f55"], [25, "#a3326f"], [35, "#d93d8a"], [50, "#ff5fae"]], ticks: ["5 min", "15", "25", "35", "50+"] },
  capacity: { label: "GP capacity", question: "Is there enough care?", reading: "GP visits a year within reach per resident, compared with the national average. Magenta is below it, cyan above.",
    stops: [[0.5, "#ff4fa3"], [0.8, "#b9487e"], [1, "#4a4450"], [1.2, "#3f8c97"], [1.5, "#4fc3d1"]], ticks: ["50%", "80%", "average", "120%", "150%"] },
  waits: { label: "Waiting times", question: "How long are the waits?", reading: "Share of non-urgent GP visits that waited more than 7 days, by municipality (THL). Brighter magenta is longer.",
    stops: [[20, "#3b2733"], [40, "#6b2f55"], [55, "#a3326f"], [70, "#d93d8a"], [85, "#ff5fae"]], ticks: ["20%", "40%", "55%", "70%", "85%"] },
  language: { label: "Language need", question: "Who may need an interpreter?", reading: "Residents whose mother tongue is not Finnish, Swedish or Sami, per 2 km square (municipal share × residents).",
    stops: [[0, "#1f2b2e"], [50, "#256a72"], [300, "#2f9aa6"], [1500, "#4fc3d1"], [6000, "#9fe8f0"]], ticks: ["0", "50", "300", "1,500", "6,000+"] },
};
const lensFor: Record<Resource, Lens> = { gp: "capacity", interpreter: "language", clinic: "travel" };

type Story = { id: number; title: string; body: string };
type Choice = { resource: Resource; row: Ranked };
type Progress = { scenarios: number; total: number; label: string; leader: string; at: [number, number] };

function square(lon: number, lat: number, halfKm: number) {
  const dLat = halfKm / 111.32, dLon = halfKm / (111.32 * Math.cos(lat * Math.PI / 180));
  return [[[lon - dLon, lat - dLat], [lon + dLon, lat - dLat], [lon + dLon, lat + dLat], [lon - dLon, lat + dLat], [lon - dLon, lat - dLat]]];
}
const cellShapes = data.cells.map(([lon, lat]) => square(lon, lat, data.cell_km * 0.42));

function useCountUp(value: number) {
  const [shown, setShown] = useState(value);
  const from = useRef(value);
  useEffect(() => {
    const start = performance.now(), begin = from.current, duration = reducedMotion() ? 0 : 900;
    let frame = 0;
    const step = (now: number) => {
      const k = duration ? Math.min(1, (now - start) / duration) : 1, eased = 1 - (1 - k) ** 3;
      setShown(begin + (value - begin) * eased);
      if (k < 1) frame = requestAnimationFrame(step); else from.current = value;
    };
    frame = requestAnimationFrame(step);
    return () => { cancelAnimationFrame(frame); from.current = value; };
  }, [value]);
  return shown;
}
function Count({ value }: { value: number }) { return <>{n0(useCountUp(value))}</>; }

export function DigitalTwin() {
  const [prep, setPrep] = useState<Prepared>();
  const [settings, setSettings] = useState<Settings>(defaultSettings);
  const [lens, setLens] = useState<Lens>("travel");
  const [county, setCounty] = useState<number>();
  const [resource, setResource] = useState<Resource>("clinic");
  const [sim, setSim] = useState<Simulation>();
  const [progress, setProgress] = useState<Progress>();
  const [choice, setChoice] = useState<Choice>();
  const [showAfter, setShowAfter] = useState(true);
  const [stories, setStories] = useState<Story[]>([{ id: 0, title: "Start here", body: `Each column is a 2 km square of mainland Finland: its height is how many people live there. White columns are the ${data.stations.length} public health stations. Pick a question on the map, then a resource on the right.` }]);
  const tell = (title: string, body: string) => setStories(list => [{ id: Date.now() + Math.random(), title, body }, ...list].slice(0, 6));

  // Nearest stations for 41,000 squares take a moment: let the page paint first.
  useEffect(() => { const t = setTimeout(() => setPrep(prepare(data)), 30); return () => clearTimeout(t); }, []);
  const current = useMemo(() => prep && week(prep, settings), [prep, settings]);
  const applied = useMemo(() => prep && current && choice ? applyResource(prep, settings, current, choice.resource, choice.row.index) : undefined, [prep, current, choice, settings]);
  const shown: Week | undefined = applied && showAfter ? applied.week : current;
  const totals = useMemo(() => prep && current && summary(prep, current, county), [prep, current, county]);
  const ranked = useMemo(() => prep && sim ? rank(prep, sim, county) : [], [prep, sim, county]);
  const gaps = useMemo(() => { const has = new Set(data.stations.map(s => s.muni)); return data.municipalities.filter((_, k) => !has.has(k)); }, []);
  const gapNames = useMemo(() => new Set(gaps.map(m => m.name)), [gaps]);
  const scenarioCount = DRAWS * (resource === "clinic" ? data.stops.length : data.stations.length);

  function update(next: Partial<Settings>, story?: [string, string]) {
    setSettings(s => ({ ...s, ...next })); setSim(undefined); setChoice(undefined);
    if (story) tell(...story);
  }
  function toggleStorm(on: boolean) {
    if (!prep || !current) return;
    const before = summary(prep, current, county).farByCar, after = summary(prep, week(prep, { ...settings, storm: on }), county).farByCar;
    setLens("travel");
    update({ storm: on }, [on ? "Snowstorm: every trip takes 30% longer" : "The roads are clear again",
      `People more than 30 minutes from a health station by car: ${n0(before)} → ${n0(after)}. The map shows travel time.`]);
  }
  function toggleBus(on: boolean) {
    if (!prep || !current) return;
    const before = summary(prep, current, county).far65NoCar, after = summary(prep, week(prep, { ...settings, busStrike: on }), county).far65NoCar;
    update({ busStrike: on }, [on ? "Bus strike: people without a car can only walk" : "Buses are running again",
      `Residents aged 65+ more than 30 minutes from care without a car: ${n0(before)} → ${n0(after)}.`]);
  }
  function toggleStation(j: number) {
    if (!prep || !current) return;
    const id = data.stations[j]!.id, closing = !settings.closed.includes(id);
    const closed = closing ? [...settings.closed, id] : settings.closed.filter(x => x !== id);
    if (closing) {
      const impact = closureImpact(prep, current, week(prep, { ...settings, closed }), j);
      const where = impact.to.map(t => `${stationName(data, t.station)} (${n0(t.people)})`).join(", ");
      tell(`You closed ${stationName(data, j)}`, `About ${n0(impact.moved)} people used it, and ${n0(impact.lostVisits)} GP visits a year are lost. They now go to ${where || "nowhere nearby"}, on average ${impact.averageExtraMinutes.toFixed(0)} minutes further by car${impact.nowFar ? `; ${n0(impact.nowFar)} of them are now more than 30 minutes away` : ""}. Click it again to reopen.`);
    } else tell(`You reopened ${stationName(data, j)}`, "Its patients and GP visits are back.");
    update({ closed });
  }
  function chooseResource(r: Resource) {
    setResource(r); setSim(undefined); setChoice(undefined); setLens(lensFor[r]);
    tell(`${resources[r].label} ${resources[r].place}`, `${resources[r].why} The map now shows ${lenses[lensFor[r]].label.toLowerCase()}. Press Simulate to test every possible place.`);
  }
  function describe(r: Resource, row: Ranked, scenarios: number) {
    const range = `${n0(row.low)}–${n0(row.high)}`;
    const value = r === "gp" ? `Of all stations, this is where an extra GP's ${n0(settings.gpVisits)} visits a year would reach the people with the fewest GP visits today.`
      : r === "interpreter" ? `${n0(row.mean)} foreign-language speakers use it as their nearest station (${range} across simulated weeks).`
      : `It would bring ${n0(row.mean)} people within 30 minutes of care (${range} across simulated weeks).`;
    const muni = data.municipalities[row.muni]!.name;
    return `${value} It was in the top 3 in ${Math.round(row.bestShare * 100)}% of ${DRAWS} simulated weeks; ${n0(scenarios)} scenarios in total.${gapNames.has(muni) ? ` Check locally: no health station is listed in ${muni}, which may be missing data.` : ""}`;
  }
  async function run() {
    if (!prep) return;
    setChoice(undefined); setSim(undefined);
    tell(`Simulating ${n0(scenarioCount)} scenarios`, `${DRAWS} different weeks, each with the ${resources[resource].short.toLowerCase()} tried in every possible place. The gold marker follows the place leading so far.`);
    const steps = simulate(prep, settings, resource, DRAWS, SEED);
    for (;;) {
      const step = steps.next();
      if (step.done) {
        const result = step.value; setSim(result); setProgress(undefined);
        const best = rank(prep, result, county)[0];
        if (best) { setChoice({ resource, row: best }); setShowAfter(true); tell(`Best place: ${best.name}`, describe(resource, best, result.scenarios)); }
        return;
      }
      const lead = resource === "clinic" ? data.stops[step.value.leader]! : data.stations[step.value.leader]!;
      setProgress({ scenarios: step.value.scenarios, total: scenarioCount, label: step.value.label,
        leader: resource === "clinic" ? lead.name : stationName(data, step.value.leader), at: [lead.lon, lead.lat] });
      await new Promise(resolve => setTimeout(resolve, 0));
    }
  }
  function pick(row: Ranked) {
    setChoice({ resource, row }); setShowAfter(true);
    if (sim) tell(`Showing ${row.name}`, describe(resource, row, sim.scenarios));
    document.getElementById("twin-map")?.scrollIntoView({ behavior: reducedMotion() ? "auto" : "smooth", block: "start" });
  }
  function chooseCounty(value: string) {
    const next = value === "" ? undefined : Number(value);
    setCounty(next); setChoice(undefined);
    tell(next === undefined ? "All of mainland Finland" : `Zoomed to ${data.counties[next]!.name}`, next === undefined ? "Figures and rankings cover the whole country." : "The figures and the ranking now cover this wellbeing services county only.");
  }
  function chooseLens(value: Lens) { setLens(value); tell(lenses[value].question, lenses[value].reading); }

  const total = totals?.residents || 1;
  return <section className={styles.twin} aria-labelledby="twin-title">
    <div className="equity-heading"><div>
      <p className="eyebrow">ACCESS DIGITAL TWIN · MAINLAND FINLAND</p>
      <h1 id="twin-title">Where would one more resource help most?</h1>
      <p>Public data on where people live and where care is. No patient is plotted, and nothing leaves this browser.</p>
    </div></div>
    <ol className={styles.steps} aria-label="How to use">
      <li className={!sim && !progress ? styles.stepOn : undefined}><b>1</b>Look: pick a question on the map</li>
      <li className={progress ? styles.stepOn : undefined}><b>2</b>Choose a resource and press Simulate</li>
      <li className={sim ? styles.stepOn : undefined}><b>3</b>Compare before and after, or click a station to close it</li>
    </ol>

    {totals && current ? <dl className={styles.kpis} aria-label={`Headline figures for ${county === undefined ? "mainland Finland" : data.counties[county]!.name}`}>
      <div><dt>More than 30 min from care by car</dt><dd><Count value={totals.farByCar} /></dd><small>{(totals.farByCar / total * 100).toFixed(1)}% of residents</small></div>
      <div><dt>Aged 65+, over 30 min without a car</dt><dd><Count value={totals.far65NoCar} /></dd><small>on foot or by bus</small></div>
      <div><dt>Below 80% of average GP capacity</dt><dd><Count value={totals.belowCapacity} /></dd><small>average: {n0(current.target)} visits per 1,000 a year</small></div>
      <div><dt>Live where most waits exceed 7 days</dt><dd><Count value={totals.longWaits} /></dd><small>over half of non-urgent GP visits (THL)</small></div>
    </dl> : null}

    <div className={styles.layout}>
      <TwinMap prep={prep} shown={shown} lens={lens} onLens={chooseLens} settings={settings} choice={choice} helped={applied?.helped}
        progress={progress} county={county} onStation={toggleStation} showAfter={showAfter} onShowAfter={setShowAfter} />
      <aside className={styles.panel} aria-label="Scenario controls">
        <label className={styles.field}>Area<select value={county ?? ""} onChange={event => chooseCounty(event.target.value)}>
          <option value="">All of mainland Finland</option>
          {data.counties.map((c, k) => ({ c, k })).sort((a, b) => a.c.name.localeCompare(b.c.name)).map(({ c, k }) => <option key={k} value={k}>{c.name}</option>)}</select></label>
        <fieldset className={styles.fieldset}><legend>Where should one more go?</legend>
          <div className={styles.choices}>{(Object.keys(resources) as Resource[]).map(r => <button key={r} className={styles.choice} aria-pressed={resource === r} onClick={() => chooseResource(r)}>
            <strong>{resources[r].short}</strong><span>{resources[r].place}</span></button>)}</div>
        </fieldset>
        <button className={`primary-button ${styles.run}`} onClick={() => void run()} disabled={!prep || progress !== undefined}>
          {!prep ? "Preparing the map…" : progress ? "Simulating…" : `Simulate ${n0(scenarioCount)} scenarios`}</button>
        <div className={styles.progress} aria-live="polite">{progress ? <>
          <div className={styles.bar}><span style={{ width: `${progress.scenarios / progress.total * 100}%` }} /></div>
          <p><strong>{n0(progress.scenarios)}</strong> of {n0(progress.total)} · {progress.label}</p><p>Leading so far: <strong>{progress.leader}</strong></p>
        </> : <p>Each scenario is one simulated week with the {resources[resource].short.toLowerCase()} in one place. Weeks vary snow, sick leave, demand and surprise closures.</p>}</div>
        <fieldset className={styles.fieldset}><legend>Disruptions</legend>
          <label className={styles.check}><input type="checkbox" checked={settings.storm} onChange={event => toggleStorm(event.target.checked)} />Snowstorm (trips 30% slower)</label>
          <label className={styles.check}><input type="checkbox" checked={settings.busStrike} onChange={event => toggleBus(event.target.checked)} />Bus strike</label>
          <p className={styles.hint}>Click a white station column on the map to close it.{settings.closed.length ? ` ${settings.closed.length} closed.` : ""}</p>
          {settings.closed.length ? <button className="text-button" onClick={() => update({ closed: [] }, ["All stations reopened", "Every health station is open again."])}>Reopen all</button> : null}
        </fieldset>
        <section className={styles.feed} aria-label="What just happened">
          <h2>What just happened</h2>
          <div aria-live="polite">{stories.map((story, k) => <article key={story.id} className={k === 0 ? styles.latest : undefined}><h3>{story.title}</h3><p>{story.body}</p></article>)}</div>
        </section>
      </aside>
    </div>

    {sim ? <section className={styles.results} aria-labelledby="results-title">
      <h2 id="results-title">Best places for {resources[resource].label.toLowerCase()}{county === undefined ? "" : ` in ${data.counties[county]!.name}`}</h2>
      <p className={styles.unit}>Ranked by {resources[resource].unit}, averaged over {DRAWS} simulated weeks. Click one to see it on the map.</p>
      <ol className={styles.ranking}>{ranked.slice(0, 8).map((row, k) => {
        const active = choice?.row.index === row.index, max = ranked[0]!.mean || 1, gap = gapNames.has(data.municipalities[row.muni]!.name);
        return <li key={row.index}><button aria-pressed={active} onClick={() => pick(row)}>
          <span className={styles.rankNo}>{k + 1}</span>
          <span className={styles.rankName}>{row.name}{gap ? <em> · check locally</em> : null}<small>{data.counties[row.county]!.name} · top 3 in {Math.round(row.bestShare * 100)}% of weeks</small></span>
          <span className={styles.rankBar} aria-hidden="true"><i style={{ width: `${row.mean / max * 100}%` }} /></span>
          <span className={styles.rankValue}>{n0(row.mean)}</span></button></li>;
      })}</ol>
      {choice?.resource === "gp" && applied && current ? <p className={styles.unit}>People who would see a GP at {choice.row.name} reach {n0(applied.recipientsAccess)} GP visits per 1,000 a year today; the average is {n0(current.target)}.</p> : null}
    </section> : null}

    <div className={styles.notes}>
      <section aria-labelledby="privacy-title"><h2 id="privacy-title">What this twin does not contain</h2>
        <ul><li>No patients, referrals, addresses or appointments.</li><li>No nationality, citizenship or immigration status. Language need is a municipal share of residents by mother tongue, never a person.</li>
          <li>Population is Statistics Finland&apos;s 1 km grid, summed into 2 km squares.</li><li>Everything runs in this browser.</li></ul></section>
      <section aria-labelledby="method-title"><h2 id="method-title">How the numbers work</h2>
        <p><strong>Travel time</strong> is estimated from straight-line distance with a road detour: by car at 30–70 km/h depending on the area, or without a car on foot or by bus with an 8–60 minute wait. It is not a route planner.</p>
        <p><strong>GP capacity</strong>: each station delivers the GP visits its municipality publishes (THL), shared among everyone within 30 minutes (two-step floating catchment).</p>
        <p><strong>Assumptions</strong>: one GP adds {n0(settings.gpVisits)} visits a year; {Math.round(settings.noCar65 * 100)}% of over-65s travel without a car.</p></section>
      <section aria-labelledby="sources-title"><h2 id="sources-title">Sources and gaps</h2>
        <ul>{data.sources.map(source => <li key={source.id}><a href={source.url} target="_blank" rel="noreferrer">{source.publisher} ↗</a> · {source.title}, {source.licence}</li>)}</ul>
        <p>{gaps.length} municipalities have no health station in either listing ({gaps.map(m => m.name).join(", ")}). Some do have one, so results there are marked “check locally”. Åland is excluded: its health care is run by ÅHS.</p></section>
    </div>
  </section>;
}

type MapProps = { prep?: Prepared; shown?: Week; lens: Lens; onLens: (lens: Lens) => void; settings: Settings; choice?: Choice; helped?: { cell: number; amount: number }[];
  progress?: Progress; county?: number; onStation: (j: number) => void; showAfter: boolean; onShowAfter: (value: boolean) => void };

function TwinMap({ prep, shown, lens, onLens, settings, choice, helped, progress, county, onStation, showAfter, onShowAfter }: MapProps) {
  const container = useRef<HTMLDivElement>(null);
  const mapRef = useRef<MapLibreMap | null>(null);
  const [ready, setReady] = useState(false);
  const [failed, setFailed] = useState(false);
  const [tip, setTip] = useState<{ x: number; y: number; text: string }>();
  const latest = useRef({ shown, onStation });
  latest.current = { shown, onStation };

  useEffect(() => {
    let cancelled = false;
    void (async () => {
      try {
        const maplibre = (await import("maplibre-gl")).default;
        if (cancelled || !container.current) return;
        const map = new maplibre.Map({ container: container.current, style: darkStyle, ...finland, maxPitch: 75, attributionControl: { compact: true } });
        mapRef.current = map;
        const fallback = setTimeout(() => { if (!map.isStyleLoaded()) map.setStyle(blankStyle); }, 6000);
        map.on("error", () => { if (!map.isStyleLoaded()) { clearTimeout(fallback); map.setStyle(blankStyle); } });
        map.on("style.load", () => {
          clearTimeout(fallback);
          if (map.getSource("cells")) return;
          const empty = { type: "FeatureCollection" as const, features: [] };
          for (const id of ["cells", "stations", "arcs", "pick", "scan"]) map.addSource(id, { type: "geojson", data: empty });
          map.addLayer({ id: "cells", type: "fill-extrusion", source: "cells", paint: { "fill-extrusion-height": 0, "fill-extrusion-color": ["get", "c"], "fill-extrusion-opacity": 0.9 } });
          map.addLayer({ id: "stations", type: "fill-extrusion", source: "stations", paint: { "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 4, ["get", "h"], 9, ["/", ["get", "h"], 8]], "fill-extrusion-color": ["get", "c"], "fill-extrusion-opacity": 0.95 } });
          map.addLayer({ id: "arcs", type: "line", source: "arcs", paint: { "line-color": "#f0ab00", "line-width": 1.6, "line-opacity": 0.85 } });
          map.addLayer({ id: "scan", type: "circle", source: "scan", paint: { "circle-radius": 16, "circle-color": "#f0ab00", "circle-opacity": 0.3, "circle-stroke-color": "#f0ab00", "circle-stroke-width": 2 } });
          map.addLayer({ id: "pick", type: "fill-extrusion", source: "pick", paint: { "fill-extrusion-height": ["interpolate", ["linear"], ["zoom"], 4, 40000, 9, 5000], "fill-extrusion-color": "#f0ab00", "fill-extrusion-opacity": 0.95 } });
          map.on("mousemove", "cells", event => {
            const i = event.features?.[0]?.properties?.i as number | undefined, w = latest.current.shown;
            if (i === undefined || !w) return;
            const cell = data.cells[i]!, area = data.municipalities[cell[4]]!;
            const go = w.nearest[i]! >= 0 ? stationName(data, w.nearest[i]!) : "no station nearby";
            setTip({ x: event.point.x, y: event.point.y, text: `${area.name} · ${n0(cell[2])} residents (${n0(cell[3])} aged 65+)\nNearest: ${go}, ${Math.round(w.carMin[i]!)} min by car, ${Math.round(w.noCarMin[i]!)} min without\nGP visits within reach: ${n0(w.access[i]!)} per 1,000 a year (average ${n0(w.target)})\nWaits over 7 days: ${area.wait_over_7_days ?? "?"}% · foreign-language speakers: ${Math.round(area.foreign_language * 100)}%` });
          });
          map.on("mousemove", "stations", event => {
            const props = event.features?.[0]?.properties;
            if (props) setTip({ x: event.point.x, y: event.point.y, text: `${props.name}\n${props.detail}\nClick to ${props.closed ? "reopen" : "close"} it in this scenario` });
            map.getCanvas().style.cursor = "pointer";
          });
          map.on("click", "stations", event => { const j = event.features?.[0]?.properties?.j as number | undefined; if (j !== undefined) latest.current.onStation(j); });
          map.on("mouseleave", "cells", () => setTip(undefined));
          map.on("mouseleave", "stations", () => { setTip(undefined); map.getCanvas().style.cursor = ""; });
          setReady(true);
        });
      } catch { if (!cancelled) setFailed(true); }
    })();
    return () => { cancelled = true; mapRef.current?.remove(); mapRef.current = null; };
  }, []);

  // Columns rise from the ground whenever the question changes, so every switch is visible.
  const grown = useRef(false);
  useEffect(() => {
    const map = mapRef.current;
    if (!ready || !map || !prep) return;
    const start = performance.now(), duration = reducedMotion() ? 0 : grown.current ? 800 : 2000;
    grown.current = true;
    let frame = 0;
    const step = (now: number) => {
      const k = duration ? Math.min(1, (now - start) / duration) : 1, eased = 1 - (1 - k) ** 3;
      // Taller at country scale, shorter close up, so zooming in never turns columns into walls.
      if (map.getLayer("cells")) map.setPaintProperty("cells", "fill-extrusion-height",
        ["interpolate", ["linear"], ["zoom"], 4, ["*", ["sqrt", ["get", "pop"]], 160 * eased], 9, ["*", ["sqrt", ["get", "pop"]], 20 * eased]]);
      if (k < 1) frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [ready, prep, lens]);

  useEffect(() => {
    const source = mapRef.current?.getSource("cells") as GeoJSONSource | undefined;
    if (!ready || !source || !shown) return;
    const stops = lenses[lens].stops;
    const colour = (v: number) => { let k = 0; while (k < stops.length - 1 && v > (stops[k]![0] + stops[k + 1]![0]) / 2) k++; return stops[k]![1]; };
    source.setData({ type: "FeatureCollection", features: data.cells.map((cell, i) => {
      const area = data.municipalities[cell[4]]!;
      const value = lens === "travel" ? shown.carMin[i]! : lens === "capacity" ? shown.access[i]! / shown.target : lens === "waits" ? area.wait_over_7_days ?? 0 : cell[2] * area.foreign_language;
      return { type: "Feature", properties: { i, pop: cell[2], c: colour(value) }, geometry: { type: "Polygon", coordinates: cellShapes[i]! } };
    }) });
  }, [ready, shown, lens]);

  useEffect(() => {
    const source = mapRef.current?.getSource("stations") as GeoJSONSource | undefined;
    if (!ready || !source || !prep) return;
    source.setData({ type: "FeatureCollection", features: data.stations.map((station, j) => {
      const closed = settings.closed.includes(station.id), hours = station.hours;
      const detail = `${n0(prep.capacity[j]!)} GP visits a year · ${hours ? `open ${hours.day + hours.extended} h a week${hours.extended ? `, ${hours.extended} h outside 8–16` : ""}` : "opening hours not listed"}`;
      return { type: "Feature", properties: { j, name: `${stationName(data, j)}${closed ? " (closed)" : ""}`, detail, closed, h: closed ? 1500 : 26000, c: closed ? "#6b6470" : "#f4eff5" },
        geometry: { type: "Polygon", coordinates: square(station.lon, station.lat, 1.1) } };
    }) });
  }, [ready, prep, settings.closed]);

  // While simulating, a gold marker follows the place leading so far.
  useEffect(() => {
    const source = mapRef.current?.getSource("scan") as GeoJSONSource | undefined;
    if (!ready || !source) return;
    source.setData({ type: "FeatureCollection", features: progress ? [{ type: "Feature", properties: {}, geometry: { type: "Point", coordinates: progress.at } }] : [] });
  }, [ready, progress]);

  // The chosen place: the camera flies in, a gold column rises, and lines grow out to the squares it helps.
  useEffect(() => {
    const map = mapRef.current;
    const pick = map?.getSource("pick") as GeoJSONSource | undefined, arcs = map?.getSource("arcs") as GeoJSONSource | undefined;
    if (!ready || !map || !pick || !arcs) return;
    const empty = { type: "FeatureCollection" as const, features: [] };
    if (!choice) { pick.setData(empty); arcs.setData(empty); return; }
    const { lon, lat } = choice.row;
    pick.setData({ type: "FeatureCollection", features: [{ type: "Feature", properties: {}, geometry: { type: "Polygon", coordinates: square(lon, lat, 1.6) } }] });
    map.flyTo({ center: [lon, lat], zoom: choice.resource === "interpreter" ? 10 : 8.6, pitch: 60, bearing: map.getBearing() + 25, duration: reducedMotion() ? 0 : 2800, essential: true });
    const targets = [...(helped ?? [])].sort((a, b) => b.amount - a.amount).slice(0, 160).map(h => data.cells[h.cell]!);
    const start = performance.now() + (reducedMotion() ? 0 : 1800), duration = reducedMotion() ? 0 : 1400;
    let frame = 0;
    const step = (now: number) => {
      const k = duration ? Math.max(0, Math.min(1, (now - start) / duration)) : 1, eased = 1 - (1 - k) ** 3;
      arcs.setData({ type: "FeatureCollection", features: targets.map(t => ({ type: "Feature", properties: {}, geometry: { type: "LineString", coordinates: [[lon, lat], [lon + (t[0] - lon) * eased, lat + (t[1] - lat) * eased]] } })) });
      if (k < 1) frame = requestAnimationFrame(step);
    };
    frame = requestAnimationFrame(step);
    return () => cancelAnimationFrame(frame);
  }, [ready, choice, helped]);

  useEffect(() => {
    const map = mapRef.current;
    if (!ready || !map || choice) return;
    if (county === undefined) { map.flyTo({ ...finland, duration: reducedMotion() ? 0 : 2200 }); return; }
    let minLon = 99, minLat = 99, maxLon = -99, maxLat = -99;
    data.cells.forEach(([lon, lat, , , m]) => { if (data.municipalities[m]!.county === county) { minLon = Math.min(minLon, lon); maxLon = Math.max(maxLon, lon); minLat = Math.min(minLat, lat); maxLat = Math.max(maxLat, lat); } });
    map.fitBounds([[minLon, minLat], [maxLon, maxLat]], { padding: 60, pitch: 55, duration: reducedMotion() ? 0 : 2200 });
  }, [ready, county, choice]);

  const meta = lenses[lens];
  return <div id="twin-map" className={styles.mapCard}>
    <div ref={container} className={styles.map} role="img" aria-label={`3D map of mainland Finland. Column height is residents per 2 km square; colour shows ${meta.label.toLowerCase()}. White columns are health stations.`} />
    {failed ? <p className={styles.mapFallback}>The 3D map needs WebGL, which this browser has not enabled. Everything else on the page still works.</p> : null}
    {!prep && !failed ? <p className={styles.mapFallback}>Preparing 41,000 squares…</p> : null}
    <div className={styles.lensBar} role="group" aria-label="Map shows">
      {(Object.keys(lenses) as Lens[]).map(key => <button key={key} aria-pressed={lens === key} onClick={() => onLens(key)}>{lenses[key].question}</button>)}
    </div>
    <div className={styles.legend}>
      <strong>{meta.label}</strong><p>{meta.reading}</p>
      <div className={styles.swatches} aria-hidden="true">{meta.stops.map(([, c], k) => <span key={k}><i style={{ background: c }} />{meta.ticks[k]}</span>)}</div>
      <p>Height: residents · White: health station · Gold: suggestion</p>
    </div>
    <div className={styles.mapActions}>
      {choice && choice.resource !== "interpreter" ? <div className={styles.toggle} role="group" aria-label="Before or after">
        <button aria-pressed={!showAfter} onClick={() => onShowAfter(false)}>Before</button><button aria-pressed={showAfter} onClick={() => onShowAfter(true)}>After</button></div> : null}
      <button className={styles.hudButton} onClick={() => mapRef.current?.flyTo({ ...finland, duration: reducedMotion() ? 0 : 2000 })}>Whole country</button>
    </div>
    {tip ? <div className={styles.tip} style={{ left: tip.x + 14, top: tip.y + 14 }}>{tip.text}</div> : null}
  </div>;
}
