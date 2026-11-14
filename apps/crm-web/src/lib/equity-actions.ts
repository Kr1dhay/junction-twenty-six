import type { CountyPathway, StageID, StageResult } from "./pathway";

/** Reviewed evidence snapshots, not live regional findings or clinical advice. */
export const evidence = {
  navigation: {
    title: "Patient navigation services to increase cancer screenings",
    publisher: "Community Preventive Services Task Force",
    published: "2024-05-17",
    url: "https://stacks.cdc.gov/view/cdc/164181",
    summary: "Recommends patient navigation to increase breast, cervical and colorectal screening in underserved populations. Services include reminders, scheduling, transportation and translation support.",
    limitation: "Evidence largely from US screening programmes. Adapt to Finnish services; this does not establish an effect on Finnish participation or attendance.",
  },
  diagnosis: {
    title: "Guide to cancer early diagnosis",
    publisher: "World Health Organization",
    published: "2017-02-16",
    url: "https://www.who.int/publications/i/item/9789241511940",
    summary: "Identify patient and health-system barriers, improve diagnostic and referral capacity, and facilitate timely access to treatment.",
    limitation: "General implementation guidance, not a trial of an acknowledgment queue or a mandated Finnish waiting-time standard.",
  },
  strategy: {
    title: "National Cancer Strategy 2026–2035 (English edition)",
    publisher: "Ministry of Social Affairs and Health, Finland",
    published: "2025-12-17",
    url: "https://www.iccp-portal.org/sites/default/files/2026-02/National_Cancer_Strategy_2026-2035_Finland.pdf",
    summary: "Sub-objectives 2.5, 3.1 and 3.2 propose standard referral criteria so people with possible cancer symptoms are referred rapidly, regionally adapted care pathways, and peer review of comparable regional data.",
    limitation: "A strategy sets direction and targets. It is not a trial showing that these measures change waiting times or survival in a particular county.",
  },
} as const;
export type EvidenceID = keyof typeof evidence;
export const evidenceIDs = Object.keys(evidence) as EvidenceID[];

/** Reviewed plans, one per pathway stage. Numbers never come from here; they come from public data. */
export const plans: Record<StageID, {
  title: string; action: string; owner: string; why: string; steps: readonly string[];
  resources: string; target: string; measure: string; source: EvidenceID;
}> = {
  screening: {
    title: "Make screening invitations easier to act on",
    action: "Multilingual invitations + navigator outreach",
    owner: "Regional screening coordinator",
    why: "Participation below the national figure warrants checking whether invitations are understood and what practical barriers exist. A county average does not show which groups are missing or why.",
    steps: ["Co-design plain-language invitations with community partners and professional translators.", "Offer opt-in navigator follow-up and help with booking.", "Review participation by invitation cohort and record reasons for non-participation voluntarily."],
    resources: "Proposed pilot: 0.2 FTE navigator, professional translation review, invitation-system support and a community partner.",
    target: "Over 12 weeks, close 5 percentage points of the gap to the national figure in one programme; review sample size and uncertainty before interpreting change.",
    measure: "Screened ÷ invited, by programme and invitation cohort; percentage-point gap to Finland and to the 80% strategy target.",
    source: "navigation",
  },
  access: {
    title: "Open a faster route for possible cancer symptoms",
    action: "Standard referral criteria + protected symptom appointments",
    owner: "Primary care service director",
    why: "A high share of GP appointments waiting over seven days suggests a congested front door. It does not show that cancer diagnoses are delayed in this county.",
    steps: ["Agree standard referral criteria for possible cancer symptoms with the receiving specialty.", "Protect same-week appointment capacity for people who meet the criteria.", "Record first-contact and referral dates so symptom-to-referral time can be reviewed."],
    resources: "Proposed pilot: clinical lead time to agree criteria, a share of weekly appointment capacity, and a first-contact date field in the patient system.",
    target: "Over 12 weeks, see at least 90% of people who meet the criteria within 7 days. This is a proposed service target, not a national standard.",
    measure: "Share of criteria-positive contacts seen within 7 days; median days from first contact to referral.",
    source: "strategy",
  },
  barriers: {
    title: "Remove practical barriers before the visit",
    action: "Interpreter coordination + travel and fee guidance",
    owner: "Patient navigator",
    why: "More people here than nationally report that travel connections or client fees hampered their care. The survey covers all health services, not cancer appointments specifically.",
    steps: ["Ask about interpreter, travel and cost concerns voluntarily at booking.", "Coordinate qualified interpretation and explain travel-support and fee-relief routes without promising eligibility.", "Offer an accessible rescheduling channel and review attendance alongside rescheduling."],
    resources: "Proposed pilot: navigator booking time, interpreter capacity, and a locally checked travel-support and client-fee information sheet.",
    target: "Over 12 weeks, improve attendance among people who report a barrier by 5 percentage points without increasing unresolved rescheduling.",
    measure: "Attended ÷ scheduled appointments by cohort; separately track rescheduled ÷ scheduled and unresolved cases.",
    source: "navigation",
  },
  referral: {
    title: "Give every referral a named next step",
    action: "Shared acknowledgment queue + escalation",
    owner: "Referral service lead",
    why: "A lower share of specialist referrals processed within three days points to a handoff that needs an owner. The figure covers all specialties, not cancer referrals alone.",
    steps: ["Record referral sent and receiving-service acknowledgment as separate events.", "Assign a queue owner and agree a local review threshold with clinical staff.", "Review overdue items daily and escalate unresolved handoffs without changing clinical urgency."],
    resources: "Proposed pilot: 15 minutes of daily queue review, a service lead, and event integration with the receiving service.",
    target: "Within 8 weeks, acknowledge at least 90% within 2 working days. This is a proposed service target, not a national clinical standard.",
    measure: "Share acknowledged within 2 working days; median and p90 time to acknowledgment once event timestamps are available.",
    source: "diagnosis",
  },
  outcomes: {
    title: "Review the diagnostic and treatment pathway with peers",
    action: "Regional pathway review + peer comparison",
    owner: "Regional cancer centre lead",
    why: "Survival below the national figure points later in the pathway: diagnosis, staging or treatment. Survival also reflects age, stage mix and small case numbers, so it is not proof of a treatment difference.",
    steps: ["Compare stage at diagnosis and time from referral to first treatment with a peer county for the affected cancer.", "Map the regional care pathway against the national pathway description and note where patients wait or travel.", "Take the findings to the regional cancer centre's peer review and agree one change to test."],
    resources: "Proposed: analyst time for a registry extract, one clinical lead per cancer type, and a peer county willing to compare.",
    target: "Within 6 months, complete one peer comparison and agree a pathway change with a named owner. This is a process target, not a predicted survival effect.",
    measure: "Share of patients starting treatment within the national target time; share diagnosed at stages I–II; five-year relative survival as the long-run outcome.",
    source: "strategy",
  },
};

export type Action = ReturnType<typeof buildAction>;
export function buildAction(stage: StageResult) {
  return { id: stage.id, stage: stage.name, ...plans[stage.id], gap: stage.worst?.gap ?? 0, detected: stage.behind, worst: stage.worst, measures: stage.measures };
}
/** Plans for the stages where this county is behind Finland, furthest behind first. */
export function actionsFor(pathway: CountyPathway): Action[] {
  return pathway.stages.filter(stage => stage.behind).sort((a, b) => b.score! - a.score!).map(buildAction);
}

const percent = (value: number) => `${value.toFixed(1).replace(/\.0$/, "")}%`;
const points = (value: number) => `${Math.abs(value).toFixed(1).replace(/\.0$/, "")} percentage point${Math.abs(value) === 1 ? "" : "s"}`;
const lower = (label: string) => label.replace(/^(GP)\b|^./, (first, keep) => keep ?? first.toLowerCase());

export interface Brief { county: string; gap: string; where: string; action: string; evidence: EvidenceID | null }
/** Three sentences a decision-maker can read in well under two minutes. Deterministic; no model involved. */
export function buildBrief(pathway: CountyPathway): Brief {
  const county = pathway.region.name;
  const stage = pathway.stages.find(item => item.id === pathway.furthest), worst = stage?.worst;
  if (!stage || !worst || worst.value === null) {
    return { county, evidence: null,
      gap: `${county} is level with or ahead of Finland on every pathway stage that has public county data.`,
      where: "No stage is flagged. Public data has no cancer-specific figure for the time between referral and treatment, so that part stays unmeasured.",
      action: "No action is triggered. Keep monitoring each year, and time local referrals to cover the unmeasured stage." };
  }
  const index = pathway.stages.indexOf(stage) + 1;
  const others = pathway.stages.filter(item => item.behind && item.id !== stage.id).map(item => item.name.toLowerCase());
  const ahead = pathway.stages.filter(item => item.worst && item.worst.gap! <= 0).map(item => item.name.toLowerCase());
  const plan = plans[stage.id];
  return {
    county, evidence: plan.source,
    gap: `${county} is furthest behind on ${lower(worst.spec.label)}: ${percent(worst.value)} against ${percent(worst.national)} for Finland in ${worst.year}. That is ${points(worst.gap!)} worse, ranking ${worst.rank} of ${worst.of} counties.`,
    where: `The gap opens at stage ${index} of ${pathway.stages.length}, ${stage.name.toLowerCase()}.${others.length ? ` ${county} is also behind Finland on ${list(others)}.` : ""}${ahead.length ? ` It is level with or ahead of Finland on ${list(ahead)}.` : ""}`,
    action: `${plan.action}, owned by the ${lower(plan.owner)}. ${plan.target}`,
  };
}
function list(items: string[]) {
  return items.length < 2 ? items.join("") : `${items.slice(0, -1).join(", ")} and ${items.at(-1)}`;
}
export const briefText = (brief: Brief) => [brief.gap, brief.where, brief.action].join(" ");
