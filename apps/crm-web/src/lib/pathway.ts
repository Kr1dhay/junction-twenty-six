import snapshotJSON from "./pathway-snapshot.json";

/** Public county figures from THL Sotkanet. Area averages, never individual or patient records. */
export interface Cell { value: number; count?: number }
export interface IndicatorData {
  id: number; title: string; organization: string; updated: string; year: number;
  national: Cell; values: Record<string, Cell | null>;
}
export interface Region { id: number; code: string; name: string; full_name: string; population: number | null }
export interface PathwayData {
  generated_at: string; source: string; source_url: string; national_region_id: number; live?: boolean;
  regions: Region[]; population_year: number; indicators: Record<string, IndicatorData>;
}
export const snapshot: PathwayData = snapshotJSON;

export type StageID = "screening" | "access" | "barriers" | "referral" | "outcomes";
export interface MeasureSpec { id: number; label: string; better: "higher" | "lower"; target?: number }
export interface StageSpec { id: StageID; name: string; measures: MeasureSpec[] }

/** National Cancer Strategy 2026–2035: 80% participation in every screening programme in every county. */
export const screeningTarget = 80;
/** A stage is flagged only when a measure is at least this many percentage points behind Finland. */
export const flagThreshold = 1;
/** Below this population, yearly survival figures rest on few cases and move a lot. */
export const smallPopulation = 100_000;

export const stages: StageSpec[] = [
  { id: "screening", name: "Screening", measures: [
    { id: 6103, label: "Colorectal screening participation", better: "higher", target: screeningTarget },
    { id: 3621, label: "Breast screening participation", better: "higher", target: screeningTarget },
    { id: 3620, label: "Cervical screening participation", better: "higher", target: screeningTarget },
  ] },
  { id: "access", name: "Primary care access", measures: [
    { id: 6411, label: "GP appointments that waited over 7 days", better: "lower" },
  ] },
  { id: "barriers", name: "Practical barriers", measures: [
    { id: 5201, label: "Care hampered by poor travel connections", better: "lower" },
    { id: 5208, label: "Care hampered by high client fees", better: "lower" },
  ] },
  { id: "referral", name: "Referral handling", measures: [
    { id: 13, label: "Specialist referrals processed within 3 days", better: "higher" },
  ] },
  { id: "outcomes", name: "Survival", measures: [
    { id: 3625, label: "Breast cancer five-year survival", better: "higher" },
    { id: 3627, label: "Bowel cancer five-year survival", better: "higher" },
  ] },
];
export const pathwayIndicatorIDs = stages.flatMap(stage => stage.measures.map(measure => measure.id));
export const measureSpec = (id: number) => stages.flatMap(stage => stage.measures).find(measure => measure.id === id);

const round1 = (value: number) => Math.round(value * 10) / 10;
/** Percentage points behind the reference; positive always means worse, whichever direction is better. */
export function pointsBehind(value: number, reference: number, better: MeasureSpec["better"]): number {
  return round1(better === "higher" ? reference - value : value - reference);
}

export interface RankedCounty { region: Region; value: number | null; count?: number; gap: number | null; rank: number | null }
/** All counties for one measure, best first. Equal values share a rank; counties without data come last. */
export function rankCounties(data: PathwayData, indicatorID: number): RankedCounty[] {
  const indicator = data.indicators[indicatorID], spec = measureSpec(indicatorID);
  if (!indicator || !spec) return [];
  const rows = data.regions.map(region => ({ region, cell: indicator.values[region.id] ?? null }));
  const withData = rows.filter(row => row.cell).sort((a, b) =>
    (spec.better === "higher" ? b.cell!.value - a.cell!.value : a.cell!.value - b.cell!.value) || a.region.name.localeCompare(b.region.name, "en"));
  const ranked: RankedCounty[] = [];
  withData.forEach((row, index) => {
    const previous = ranked[index - 1];
    ranked.push({ region: row.region, value: row.cell!.value, count: row.cell!.count,
      gap: pointsBehind(row.cell!.value, indicator.national.value, spec.better),
      rank: previous && previous.value === row.cell!.value ? previous.rank : index + 1 });
  });
  return [...ranked, ...rows.filter(row => !row.cell).map(row => ({ region: row.region, value: null, gap: null, rank: null }))];
}

export interface Measure {
  spec: MeasureSpec; year: number; organization: string; value: number | null; count?: number; national: number;
  /** Percentage points behind Finland; positive means worse. */
  gap: number | null;
  rank: number | null; of: number;
  /** Percentage points below the strategy target, when the measure has one. */
  targetGap: number | null;
}
export interface StageResult {
  id: StageID; name: string; measures: Measure[];
  /** 0 = best county on every measure, 1 = last on every measure. Null without data. */
  score: number | null;
  behind: boolean; worst: Measure | null;
}
export interface CountyPathway { region: Region; stages: StageResult[]; furthest: StageID | null; smallPopulation: boolean }

export function buildPathway(data: PathwayData, regionID: number): CountyPathway | undefined {
  const region = data.regions.find(item => item.id === regionID);
  if (!region) return;
  const results = stages.map((stage): StageResult => {
    const measures = stage.measures.flatMap((spec): Measure[] => {
      const indicator = data.indicators[spec.id];
      if (!indicator) return [];
      const ranking = rankCounties(data, spec.id);
      const own = ranking.find(row => row.region.id === regionID);
      const value = own?.value ?? null;
      return [{ spec, year: indicator.year, organization: indicator.organization, value, count: own?.count,
        national: indicator.national.value, gap: own?.gap ?? null, rank: own?.rank ?? null,
        of: ranking.filter(row => row.value !== null).length,
        targetGap: value !== null && spec.target !== undefined ? round1(spec.target - value) : null }];
    });
    const known = measures.filter(measure => measure.gap !== null && measure.rank !== null);
    const score = known.length
      ? known.reduce((sum, measure) => sum + (measure.of > 1 ? (measure.rank! - 1) / (measure.of - 1) : 0), 0) / known.length
      : null;
    const worst = known.reduce<Measure | null>((current, measure) => !current || measure.gap! > current.gap! ? measure : current, null);
    return { id: stage.id, name: stage.name, measures, score, behind: Boolean(worst && worst.gap! >= flagThreshold), worst };
  });
  const furthest = results.filter(stage => stage.behind)
    .reduce<StageResult | null>((current, stage) => !current || stage.score! > current.score! ? stage : current, null);
  return { region, stages: results, furthest: furthest?.id ?? null,
    smallPopulation: region.population !== null && region.population < smallPopulation };
}

/** Arithmetic on one invitation round. Invited is estimated from the published count and rounded rate. */
export function invitationRound(cell: Cell | null | undefined, target = screeningTarget) {
  if (!cell || cell.count === undefined || cell.count <= 0 || cell.value <= 0 || cell.value > 100) return null;
  const invited = Math.round(cell.count / (cell.value / 100));
  return { invited, attended: cell.count, needed: Math.max(0, Math.ceil(invited * target / 100) - cell.count) };
}
/** Participation if a share of the people who did not attend took part. Not a forecast of any action's effect. */
export function projectedParticipation(round: { invited: number; attended: number }, shareOfNonAttenders: number) {
  const share = Math.min(1, Math.max(0, shareOfNonAttenders));
  const extra = Math.round((round.invited - round.attended) * share);
  return { extra, rate: round1((round.attended + extra) / round.invited * 100) };
}
