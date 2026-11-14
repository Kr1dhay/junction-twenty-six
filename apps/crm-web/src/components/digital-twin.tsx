"use client";
import "maplibre-gl/dist/maplibre-gl.css";
import { useEffect, useMemo, useRef, useState } from "react";
import type { GeoJSONSource, Map as MapLibreMap, StyleSpecification } from "maplibre-gl";
import { defaultAssumptions, expectedWeek, groups, noDisruptions, averageAccess, resources, runScenarios, twinData,
  type Assumptions, type Disruptions, type GroupID, type Resource, type RunResult, type Site, type Suggestion } from "../lib/twin";
import styles from "./digital-twin.module.css";

const draws = 120;
const seed = 2026;
const home = { center: [24.985, 60.208] as [number, number], zoom: 10.85, pitch: 58, bearing: -16 };
const darkStyle = "https://tiles.openfreemap.org/styles/dark";
const blankStyle: StyleSpecification = { version: 8, sources: {}, layers: [{ id: "background", type: "background", paint: { "background-color": "#0c0c0c" } }] };
// Diverging access scale: below the city average (magenta) · at it (dim neutral) · above it (cyan). Checked for colour-blind separation.
const colour = { low: "#ff4fa3", mid: "#4a4450", high: "#4fc3d1", station: "#f4eff5", closed: "#6b6470", pick: "#f0ab00", library: "#8a8290" };
const number = new Intl.NumberFormat("en-GB");
const pct = (value: number, digits = 1) => `${(value * 100).toFixed(digits)}%`;
const siteLabel = (site: Site) => site.kind === "station" ? `${site.name} health station` : site.name;
const reducedMotion = () => typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

/** 250 m squares around each published cell centre, inset slightly so neighbouring columns stay distinct. */
function square(lon: number, lat: number, halfMetres: number) {
  const dLat = halfMetres / 111_320, dLon = halfMetres / (111_320 * Math.cos(lat * Math.PI / 180));
  return [[[lon - dLon, lat - dLat], [lon + dLon, lat - dLat], [lon + dLon, lat + dLat], [lon - dLon, lat + dLat], [lon - dLon, lat - dLat]]];
}
const maxResidents = Math.max(...twinData.cells.map(cell => cell[2]));
const cellGeometry = twinData.cells.map(([lon, lat]) => square(lon, lat, twinData.cell_size_m * 0.44));

type Selection = { resource: Resource; site: Site };
type View = "before" | "after";

export function DigitalTwin() {
  const [assumptions, setAssumptions] = useState<Assumptions>(defaultAssumptions);
  const [disruptions, setDisruptions] = useState<Disruptions>(noDisruptions);
  const [group, setGroup] = useState<GroupID>("everyone");
  const [result, setResult] = useState<RunResult>();
  const [progress, setProgress] = useState<number>();
  const [selection, setSelection] = useState<Selection>();
  const [view, setView] = useState<View>("before");
  const openStations = twinData.stations.filter(station => !disruptions.closed.includes(station.id)).length;
  const scenarioCount = draws * (openStations * 2 + twinData.libraries.length + 1);

  const week = useMemo(() => expectedWeek(assumptions, disruptions, selection), [assumptions, disruptions, selection]);
  const shown = view === "after" && week.after ? week.after : week.before;
  const average = useMemo(() => averageAccess(week.people, week.before, week.target), [week]);
  const changeLabel = selection ? `${resources.find(r => r.id === selection.resource)!.label.toLowerCase()} at ${siteLabel(selection.site)}` : "";
  const areaGaps = useMemo(() => {
    const gap = new Float64Array(twinData.areas.length), people = week.people[group], values = week.before[group];
    twinData.cells.forEach((cell, i) => { if (values[i]! < week.target) gap[cell[3]]! += people[i]! * (week.target - values[i]!) / week.target; });
    return twinData.areas.map((area, k) => ({ area, gap: gap[k]! })).sort((a, b) => b.gap - a.gap).slice(0, 8);
  }, [week, group]);

  function change<K extends keyof Assumptions>(key: K, value: Assumptions[K]) { setAssumptions(current => ({ ...current, [key]: value })); reset(); }
  function disrupt(next: Partial<Disruptions>) { setDisruptions(current => ({ ...current, ...next })); reset(); }
  function reset() { setResult(undefined); setSelection(undefined); setView("before"); }

  async function run() {
    setProgress(0); setSelection(undefined); setView("before");
    const outcome = await runScenarios({ draws, seed, assumptions, disruptions, yieldEvery: 3, onProgress: done => setProgress(done) });
    setResult(outcome); setProgress(undefined);
    const best = resources.map(item => outcome.byResource[item.id][0]).filter(Boolean).sort((a, b) => b!.share - a!.share)[0];
    if (best) choose(best);
  }
  function choose(suggestion: Suggestion, reveal = false) {
    setSelection({ resource: suggestion.resource, site: suggestion.site }); setView("after");
    if (reveal) document.getElementById("twin-map")?.scrollIntoView({ behavior: reducedMotion() ? "auto" : "smooth", block: "start" });
  }

  return <section className={styles.twin} aria-labelledby="twin-title">
    <div className="equity-heading">
      <div><p className="eyebrow">ACCESS DIGITAL TWIN · HELSINKI</p><h1 id="twin-title">Where would one more resource help most?</h1>
        <p>A simulation of public geography and service hours. No patient is plotted, and nothing leaves this browser.</p></div>
    </div>

    <div className={styles.layout}>
      <TwinMap shown={shown} target={week.target} group={group} disruptions={disruptions} selection={selection} view={view} onView={setView} result={result} />
      <aside className={styles.panel} aria-label="Scenario controls">
        <label className={styles.field}>Show access for<select value={group} onChange={event => setGroup(event.target.value as GroupID)}>
          {groups.map(item => <option key={item.id} value={item.id}>{item.label}</option>)}</select></label>
        <p className={styles.hint}>{groups.find(item => item.id === group)!.detail}</p>

        <fieldset className={styles.fieldset}><legend>Disruptions</legend>
          <label className={styles.check}><input type="checkbox" checked={disruptions.transitStrike} onChange={event => disrupt({ transitStrike: event.target.checked })} />Public transport strike</label>
          <label className={styles.check}><input type="checkbox" checked={disruptions.remoteInterpretingDown} onChange={event => disrupt({ remoteInterpretingDown: event.target.checked })} />Phone and video interpreting unavailable</label>
          <label className={styles.field}>Close a health station<select value={disruptions.closed[0] ?? ""} onChange={event => disrupt({ closed: event.target.value ? [Number(event.target.value)] : [] })}>
            <option value="">None</option>{[...twinData.stations].sort((a, b) => a.name.localeCompare(b.name)).map(station => <option key={station.id} value={station.id}>{station.name}</option>)}</select></label>
        </fieldset>

        <details className={styles.assumptions}><summary>Planning assumptions <span>not published · set locally</span></summary>
          <Range label="Clinicians per health station" value={assumptions.clinicians} min={2} max={20} step={1} format={v => `${v}`} onChange={v => change("clinicians", v)} />
          <Range label="Language needs met by phone or video interpreting" value={assumptions.remoteInterpreting} min={0} max={1} step={0.05} format={v => pct(v, 0)} onChange={v => change("remoteInterpreting", v)} />
          <Range label="Residents who need evening or Saturday hours" value={assumptions.extendedNeed} min={0.05} max={0.6} step={0.05} format={v => pct(v, 0)} onChange={v => change("extendedNeed", v)} />
          <Range label="Clinicians absent in a typical week" value={assumptions.absence} min={0} max={0.3} step={0.02} format={v => pct(v, 0)} onChange={v => change("absence", v)} />
          <Range label="Mobile clinic hours per week" value={assumptions.vehicleHours} min={10} max={40} step={5} format={v => `${v} h`} onChange={v => change("vehicleHours", v)} />
        </details>

        <button className={`primary-button ${styles.run}`} onClick={() => void run()} disabled={progress !== undefined}>
          {progress !== undefined ? "Simulating…" : `Run ${number.format(scenarioCount)} scenarios`}</button>
        <div className={styles.progress} aria-live="polite">{progress !== undefined
          ? <><div className={styles.bar}><span style={{ width: `${progress / scenarioCount * 100}%` }} /></div><p>{number.format(progress)} of {number.format(scenarioCount)} scenarios</p></>
          : result ? <p>{number.format(result.scenarios)} scenarios: {result.draws} simulated weeks × every placement, with random absences, demand, travel delays and closures.</p>
          : <p>Each scenario is one simulated week with one resource placed somewhere. Seeded, so a run can be repeated.</p>}</div>
      </aside>
    </div>

    <dl className={styles.kpis} aria-label="Access by group">
      {groups.map(item => <div key={item.id} className={item.id === group ? styles.active : undefined}><dt>{item.label}</dt>
        <dd>{pct(average[item.id], 0)}<span> of the city average</span></dd>
        <dd className={styles.gap}>Access gap {number.format(Math.round(week.shortfallBefore[item.id]))}{week.shortfallAfter
          ? <strong> → {number.format(Math.round(week.shortfallAfter[item.id]))}</strong> : null}</dd></div>)}
      <p>Average access for each group compared with what the average Helsinki resident can reach. The access gap is residents × how far below that average they fall{changeLabel ? `; before → after ${changeLabel}` : ""}.</p>
    </dl>

    {result ? <section className={styles.results} aria-labelledby="results-title">
      <h2 id="results-title">Best place for one more…</h2>
      <div className={styles.cards}>{resources.map(item => {
        const list = result.byResource[item.id], best = list[0];
        if (!best) return null;
        const active = selection?.resource === item.id && selection.site.id === best.site.id;
        return <article key={item.id} className={`${styles.card} ${active ? styles.cardActive : ""}`} aria-labelledby={`best-${item.id}`}>
          <p className="eyebrow">{item.label.toUpperCase()}</p>
          <h3 id={`best-${item.id}`}>{siteLabel(best.site)}</h3>
          <p className={styles.gain}><strong>{pct(best.share, 2)}</strong> of the city&apos;s access gap closed</p>
          <p className={styles.range}>Best choice in {pct(best.bestShare, 0)} of simulated weeks · 90% of weeks between {pct(best.low / result.baselineShortfall, 2)} and {pct(best.high / result.baselineShortfall, 2)}</p>
          <ol className={styles.runners}>{list.slice(1, 3).map(other => <li key={other.site.id}><button className="text-button" onClick={() => choose(other, true)}>{siteLabel(other.site)} · {pct(other.share, 2)}</button></li>)}</ol>
          <button className="secondary-button" onClick={() => choose(best, true)} aria-pressed={active}>{active ? "Shown on map" : "Show on map"}</button>
        </article>;
      })}</div>
      <details className={styles.table}><summary>All {result.byResource.clinician.length + result.byResource.interpreter.length + result.byResource.vehicle.length} placements as a table</summary>
        <table><thead><tr><th scope="col">Resource</th><th scope="col">Place</th><th scope="col">Gap closed</th><th scope="col">90% of weeks</th><th scope="col">Best in</th></tr></thead>
          <tbody>{resources.flatMap(item => result.byResource[item.id].map(row => <tr key={`${item.id}-${row.site.kind}-${row.site.id}`}>
            <td>{item.label}</td><td>{siteLabel(row.site)}</td><td>{pct(row.share, 2)}</td>
            <td>{pct(row.low / result.baselineShortfall, 2)}–{pct(row.high / result.baselineShortfall, 2)}</td><td>{pct(row.bestShare, 0)}</td></tr>))}</tbody></table>
      </details>
    </section> : null}

    <section className={styles.areas} aria-labelledby="areas-title">
      <h2 id="areas-title">Largest access gaps: {groups.find(item => item.id === group)!.label.toLowerCase()}</h2>
      <ol>{areaGaps.map(({ area, gap }) => <li key={area.id}><span>{area.name}</span><span>{number.format(Math.round(gap))} resident-equivalents</span></li>)}</ol>
      <p>Sum over the sub-district&apos;s 250 m cells of residents × how far their access falls below the city average.</p>
    </section>

    <div className={styles.notes}>
      <section aria-labelledby="privacy-title"><h2 id="privacy-title">What this twin does not contain</h2>
        <ul><li>No patients, referrals, addresses or appointment records.</li><li>No nationality, citizenship or immigration status: language need is a sub-district share of residents by mother tongue, never a person.</li>
          <li>Population is HSY&apos;s published 250 m grid; the publisher suppresses age detail in small cells.</li><li>The simulation runs in this browser. No input is sent anywhere.</li></ul></section>
      <section aria-labelledby="method-title"><h2 id="method-title">Method and limits</h2>
        <p>Access is the enhanced two-step floating catchment area (E2SFCA) with a 40-minute Gaussian travel-time decay: each station&apos;s weekly appointment hours are shared by everyone who can reach it, then each group reaches the share that suits it (interpreting, a step-free entrance, opening hours). The access gap is residents × how far below the city average they fall, summed over the four groups.</p>
        <p>Travel times are estimates from straight-line distance (walking, step-free walking, or public transport with a wait), not a journey planner; they understate trips across water. Clinician numbers and interpreting coverage are not published and are set above. Results rank places to look at with local teams; they are not a forecast of outcomes.</p></section>
      <section aria-labelledby="sources-title"><h2 id="sources-title">Sources</h2>
        <ul>{twinData.sources.map(source => <li key={source.id}><a href={source.url} target="_blank" rel="noreferrer">{source.title} ↗</a> · {source.publisher}, {source.licence}</li>)}</ul>
        <p>Snapshot {new Date(twinData.generated_at).toISOString().slice(0, 10)} · map tiles © OpenMapTiles, © OpenStreetMap contributors (OpenFreeMap).</p></section>
    </div>
  </section>;
}

function Range({ label, value, min, max, step, format, onChange }: { label: string; value: number; min: number; max: number; step: number; format: (v: number) => string; onChange: (v: number) => void }) {
  return <label className={styles.range}><span>{label}<strong>{format(value)}</strong></span>
    <input type="range" min={min} max={max} step={step} value={value} aria-valuetext={format(value)} onChange={event => onChange(Number(event.target.value))} /></label>;
}

type MapProps = { shown: ReturnType<typeof expectedWeek>["before"]; target: number; group: GroupID; disruptions: Disruptions; selection?: Selection; view: View; onView: (view: View) => void; result?: RunResult };

function TwinMap({ shown, target, group, disruptions, selection, view, onView, result }: MapProps) {
  const container = useRef<HTMLDivElement>(null);
  const mapRef = useRef<MapLibreMap | null>(null);
  const [state, setState] = useState<"loading" | "ready" | "unavailable">("loading");
  const [tip, setTip] = useState<{ x: number; y: number; text: string }>();
  const [caption, setCaption] = useState("");
  const touring = useRef(false);
  const latest = useRef({ shown, target, group });
  latest.current = { shown, target, group };

  useEffect(() => {
    let cancelled = false, frame = 0;
    void (async () => {
      try {
        const maplibre = (await import("maplibre-gl")).default;
        if (cancelled || !container.current) return;
        const map = new maplibre.Map({ container: container.current, style: darkStyle, ...home, maxPitch: 75, attributionControl: { compact: true } });
        mapRef.current = map;
        // Offline or blocked tiles: keep the twin, drop the basemap.
        const fallback = setTimeout(() => { if (!map.isStyleLoaded()) map.setStyle(blankStyle); }, 6000);
        map.on("error", () => { if (!map.isStyleLoaded()) { clearTimeout(fallback); map.setStyle(blankStyle); } });
        map.on("style.load", () => {
          clearTimeout(fallback);
          if (map.getSource("cells")) return;
          map.addSource("cells", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
          map.addSource("stations", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
          map.addSource("libraries", { type: "geojson", data: { type: "FeatureCollection", features: twinData.libraries.map(l => ({ type: "Feature", properties: { name: l.name }, geometry: { type: "Point", coordinates: [l.lon, l.lat] } })) } });
          map.addSource("pick", { type: "geojson", data: { type: "FeatureCollection", features: [] } });
          map.addLayer({ id: "cells", type: "fill-extrusion", source: "cells", paint: {
            "fill-extrusion-height": ["*", ["get", "pop"], 0],
            "fill-extrusion-color": ["interpolate", ["linear"], ["get", "v"], 0.4, colour.low, 0.7, "#b9487e", 1, colour.mid, 1.3, "#3f8c97", 1.6, colour.high],
            "fill-extrusion-opacity": 0.88 } });
          map.addLayer({ id: "libraries", type: "circle", source: "libraries", paint: { "circle-radius": 3, "circle-color": colour.library, "circle-opacity": 0.8 } });
          map.addLayer({ id: "stations", type: "fill-extrusion", source: "stations", paint: {
            "fill-extrusion-height": ["get", "h"], "fill-extrusion-color": ["get", "c"], "fill-extrusion-opacity": 0.95 } });
          map.addLayer({ id: "pick-glow", type: "circle", source: "pick", paint: { "circle-radius": 18, "circle-color": colour.pick, "circle-opacity": 0.25, "circle-blur": 0.6, "circle-pitch-alignment": "map" } });
          map.addLayer({ id: "pick", type: "fill-extrusion", source: "pick", filter: ["==", ["geometry-type"], "Polygon"], paint: {
            "fill-extrusion-height": 3200, "fill-extrusion-color": colour.pick, "fill-extrusion-opacity": 0.95 } });
          map.on("mousemove", "cells", event => {
            const i = event.features?.[0]?.properties?.i as number | undefined;
            if (i === undefined) return;
            const { shown: values, target: t, group: g } = latest.current;
            const cell = twinData.cells[i]!, area = twinData.areas[cell[3]]!;
            setTip({ x: event.point.x, y: event.point.y, text: `${area.name} · ${number.format(cell[2])} residents · access ${Math.round(values[g][i]! / t * 100)}% of the city average` });
          });
          map.on("mousemove", "stations", event => {
            const name = event.features?.[0]?.properties?.name as string | undefined;
            if (name) setTip({ x: event.point.x, y: event.point.y, text: name });
          });
          map.on("mouseleave", "cells", () => setTip(undefined));
          map.on("mouseleave", "stations", () => setTip(undefined));
          setState("ready");
          // Rise from the ground: heights grow over 1.6 s.
          const scale = 1900 / maxResidents, start = performance.now(), duration = reducedMotion() ? 0 : 1600;
          const grow = (now: number) => {
            const k = duration ? Math.min(1, (now - start) / duration) : 1, eased = 1 - (1 - k) ** 3;
            if (map.getLayer("cells")) map.setPaintProperty("cells", "fill-extrusion-height", ["*", ["get", "pop"], scale * eased]);
            if (k < 1) frame = requestAnimationFrame(grow);
          };
          frame = requestAnimationFrame(grow);
        });
      } catch { if (!cancelled) setState("unavailable"); }
    })();
    return () => { cancelled = true; cancelAnimationFrame(frame); mapRef.current?.remove(); mapRef.current = null; };
  }, []);

  // Cells: colour is access for the chosen group relative to the city average.
  useEffect(() => {
    const source = mapRef.current?.getSource("cells") as GeoJSONSource | undefined;
    if (state !== "ready" || !source) return;
    const values = shown[group];
    source.setData({ type: "FeatureCollection", features: twinData.cells.map((cell, i) => ({ type: "Feature", properties: { i, pop: cell[2], v: target ? values[i]! / target : 1 },
      geometry: { type: "Polygon", coordinates: cellGeometry[i]! } })) });
  }, [state, shown, target, group]);

  useEffect(() => {
    const map = mapRef.current;
    const stations = map?.getSource("stations") as GeoJSONSource | undefined, pick = map?.getSource("pick") as GeoJSONSource | undefined;
    if (state !== "ready" || !map || !stations || !pick) return;
    stations.setData({ type: "FeatureCollection", features: twinData.stations.map(station => {
      const closed = disruptions.closed.includes(station.id);
      return { type: "Feature", properties: { name: `${station.name} health station${closed ? " · closed in this scenario" : ""}`, h: closed ? 250 : 2400, c: closed ? colour.closed : colour.station },
        geometry: { type: "Polygon", coordinates: square(station.lon, station.lat, 85) } };
    }) });
    const site = selection?.site;
    pick.setData({ type: "FeatureCollection", features: site && view === "after" ? [
      { type: "Feature", properties: {}, geometry: { type: "Polygon", coordinates: square(site.lon, site.lat, 95) } },
      { type: "Feature", properties: {}, geometry: { type: "Point", coordinates: [site.lon, site.lat] } }] : [] });
    if (site && view === "after" && !touring.current) {
      map.flyTo({ center: [site.lon, site.lat], zoom: 11.9, pitch: 56, bearing: map.getBearing() + 30, duration: reducedMotion() ? 0 : 2600, essential: true });
    }
  }, [state, disruptions, selection, view]);

  async function tour() {
    const map = mapRef.current;
    if (!map || !result || touring.current) return;
    touring.current = true;
    const stops = resources.map(item => ({ item, best: result.byResource[item.id][0] })).filter(stop => stop.best);
    const motion = !reducedMotion();
    for (const [k, { item, best }] of stops.entries()) {
      setCaption(`${k + 1} / ${stops.length} · ${item.label} → ${siteLabel(best!.site)} · ${pct(best!.share, 2)} of the access gap`);
      map.flyTo({ center: [best!.site.lon, best!.site.lat], zoom: 12.2, pitch: 60, bearing: -40 + k * 70, duration: motion ? 4200 : 0, essential: true });
      await new Promise(resolve => setTimeout(resolve, motion ? 5200 : 1200));
    }
    map.flyTo({ ...home, duration: motion ? 3500 : 0, essential: true });
    setCaption("");
    touring.current = false;
  }

  return <div id="twin-map" className={styles.mapCard}>
    <div ref={container} className={styles.map} role="img" aria-label={`3D map of Helsinki: column height is residents per 250 m cell, colour is access for ${groups.find(item => item.id === group)!.label.toLowerCase()} compared with the city average. The same figures are listed below the map.`} />
    {state === "unavailable" ? <p className={styles.mapFallback}>The 3D map needs WebGL, which this browser has not enabled. All results and tables below still work.</p> : null}
    {state === "loading" ? <p className={styles.mapFallback}>Loading the 3D map…</p> : null}
    <div className={styles.hud}>
      <div className={styles.legend} aria-hidden="true"><span>Colour: access vs. city average</span><i /><span className={styles.legendScale}><b>Far below</b><b>Average</b><b>Above</b></span><span>Height: residents · White: health stations{result ? " · Gold: suggestion" : ""}</span></div>
      <div className={styles.mapActions}>
        {selection ? <div className={styles.toggle} role="group" aria-label="Map shows">{(["before", "after"] as const).map(option =>
          <button key={option} className={styles.hudButton} aria-pressed={view === option} onClick={() => onView(option)}>{option === "before" ? "Before" : "After"}</button>)}</div> : null}
        {result ? <button className={styles.hudButton} onClick={() => void tour()}>Cinematic tour</button> : null}
        <button className={styles.hudButton} onClick={() => mapRef.current?.flyTo({ ...home, duration: reducedMotion() ? 0 : 1800 })}>Reset view</button>
      </div>
    </div>
    {caption ? <p className={styles.caption} aria-live="polite">{caption}</p> : null}
    {tip ? <div className={styles.tip} style={{ left: tip.x + 14, top: tip.y + 14 }}>{tip.text}</div> : null}
    {view === "after" && selection ? <p className={styles.viewTag}>After: {resources.find(item => item.id === selection.resource)!.label.toLowerCase()} at {siteLabel(selection.site)}</p> : null}
  </div>;
}

