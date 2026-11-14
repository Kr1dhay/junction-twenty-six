/** Reviewed evidence snapshots, not live regional findings or clinical advice. */
export const evidence = {
  navigation: {
    title: "Patient navigation services to increase cancer screenings",
    publisher: "Community Preventive Services Task Force",
    published: "2024-05-17",
    url: "https://stacks.cdc.gov/view/cdc/164181",
    summary: "Recommends patient navigation to increase breast, cervical and colorectal screening in underserved populations. Services include reminders, scheduling, transportation and translation support.",
    limitation: "Evidence largely from US screening programmes. Adapt to Finnish services; this does not establish an effect on Finnish appointment attendance.",
  },
  diagnosis: {
    title: "Guide to cancer early diagnosis",
    publisher: "World Health Organization",
    published: "2017-02-16",
    url: "https://www.who.int/publications/i/item/9789241511940",
    summary: "Identify patient and health-system barriers, improve diagnostic and referral capacity, and facilitate timely access to treatment.",
    limitation: "General implementation guidance, not a trial of an acknowledgment queue or a mandated Finnish waiting-time standard.",
  },
} as const;

export type ActionID = "screening" | "acknowledgment" | "attendance";
export type Scenario = "baseline" | "improved";
export type EvidenceID = keyof typeof evidence;
export const actionIDs: ActionID[] = ["screening", "acknowledgment", "attendance"];

/** Calculations only use explicit numerator/denominator counts. No inferred SES. */
export function rate(numerator: number, denominator: number): number | null {
  if (!Number.isInteger(numerator) || !Number.isInteger(denominator) || denominator <= 0 || numerator < 0 || numerator > denominator) return null;
  return numerator / denominator * 100;
}
export function percentagePointGap(a: [number, number], b: [number, number]): number | null {
  const first = rate(...a), second = rate(...b);
  return first === null || second === null ? null : Math.round((second - first) * 10) / 10;
}

const plans = {
  screening: {
    stage: "Screening",
    title: "Make screening invitations easier to act on",
    action: "Multilingual invitations + navigator outreach",
    owner: "Regional screening coordinator",
    why: "A lower participation rate warrants checking invitation comprehension and practical barriers. Language preference is a support need, not a proxy for socioeconomic status or a proven cause.",
    steps: ["Co-design plain-language invitations with community partners and professional translators.", "Offer opt-in navigator follow-up and help with booking.", "Review participation by invitation cohort and record reasons for non-participation voluntarily."],
    resources: "Proposed pilot: 0.2 FTE navigator, professional translation review, invitation-system support and a community partner.",
    target: "Over 12 weeks, reduce the participation gap by 5 percentage points against the baseline cohort; review sample size and uncertainty before interpreting change.",
    measure: "Screened ÷ eligible invitees, by cohort; percentage-point gap.",
    source: "navigation" as EvidenceID,
  },
  acknowledgment: {
    stage: "Referral → acknowledgment",
    title: "Give every referral a named next step",
    action: "Shared acknowledgment queue + escalation",
    owner: "Referral service lead",
    why: "Unacknowledged referrals indicate a handoff visibility problem, not necessarily delayed treatment. A named queue owner makes missing handoffs actionable.",
    steps: ["Record referral sent and receiving-service acknowledgment as separate events.", "Assign a queue owner and agree a local review threshold with clinical staff.", "Review overdue items daily and escalate unresolved handoffs without changing clinical urgency."],
    resources: "Proposed pilot: 15 minutes of daily queue review, a service lead, and event integration with the receiving service.",
    target: "Within 8 weeks, acknowledge at least 90% within 2 working days. This is a proposed service target, not a national clinical standard.",
    measure: "Share acknowledged within 2 working days; median and p90 time to acknowledgment once event timestamps are available.",
    source: "diagnosis" as EvidenceID,
  },
  attendance: {
    stage: "Appointment access",
    title: "Remove practical barriers before the visit",
    action: "Interpreter coordination + travel-support guidance",
    owner: "Patient navigator",
    why: "A difference in attendance among people reporting access barriers supports a barrier review. It does not demonstrate that those barriers caused missed appointments.",
    steps: ["Ask about interpreter and travel needs voluntarily at booking.", "Coordinate qualified interpretation and explain available travel-support routes without promising eligibility.", "Offer an accessible rescheduling channel and review attendance alongside rescheduling."],
    resources: "Proposed pilot: navigator booking time, interpreter capacity, and a locally checked travel-support information sheet.",
    target: "Over 12 weeks, improve attendance in the access-support cohort by 5 percentage points without reducing access or increasing unresolved rescheduling.",
    measure: "Attended ÷ scheduled appointments by cohort; separately track rescheduled ÷ scheduled and unresolved cases.",
    source: "navigation" as EvidenceID,
  },
} as const;

export function buildAction(id: ActionID, scenario: Scenario) {
  // Fictional aggregate cohorts only. Never derive these from open/spent referrals.
  const improved = scenario === "improved";
  const counts: Record<ActionID, { a: [number, number]; b: [number, number]; labels: [string, string] }> = {
    screening: { a: [improved ? 144 : 112, 200], b: [144, 200], labels: ["Invitees requesting language support", "Comparison invitation cohort"] },
    acknowledgment: { a: [improved ? 96 : 68, 100], b: [90, 100], labels: ["Acknowledged within 2 working days", "Proposed service target"] },
    attendance: { a: [improved ? 90 : 72, 100], b: [90, 100], labels: ["Appointments with reported access barriers", "Comparison appointment cohort"] },
  };
  const sample = counts[id];
  const gap = percentagePointGap(sample.a, sample.b)!;
  return { id, ...plans[id], ...sample, gap, detected: gap > 0, period: "Illustrative 12-week cohort", basis: "Synthetic scenario · not observed CRM data" };
}
