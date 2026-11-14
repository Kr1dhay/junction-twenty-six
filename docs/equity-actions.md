# CRM equity actions

Open the authenticated CRM and select **Equity actions** in the sidebar.
This opens the dedicated `/equity-actions` page. Direct navigation uses the same
automatic demo-session entry as the referrals page; it is not verified clinician
authentication. On phones, a compact page-navigation row replaces the sidebar links.

The page answers three questions for one wellbeing services county, in order:
what the gap is, where in the care pathway it opens, and what to do about it.

- **County picker.** All 23 areas published by Sotkanet (21 wellbeing services
  counties, the City of Helsinki and Åland). The choice is kept in `?county=<code>`,
  so a county view can be linked or reloaded.
- **Two-minute brief.** Three sentences built from the figures: the gap, the stage,
  the action. **Read aloud** uses the browser's speech synthesis. **Explain with AI**
  is optional and described below.
- **Pathway at a glance.** Five stages: screening, primary care access, practical
  barriers, referral handling, survival. A stage is "behind Finland" when any of its
  measures is at least 1 percentage point worse than the national figure; the stage
  with the weakest average county rank is marked "furthest behind".
- **The unmeasured stage.** Public data has no cancer-specific county figure between
  referral and treatment. The page reads this workspace's own referrals once
  (no polling) and shows open referrals, longest wait and median time to verification.
  These are synthetic demo referrals and are labelled as such.
- **How every county compares.** A ranked dot plot for any measure, with the national
  figure and, for screening, the 80% strategy target. Selecting a row briefs that county.
- **Action plans.** Only for stages that are behind, furthest first. Each plan has an
  accountable owner, steps, resources, a measure, a pilot target, a dated source and
  its limits. The screening plan adds a slider: how many more attendances reach 80%.

## Data

| Stage | Sotkanet indicator | Publisher |
| --- | --- | --- |
| Screening | 6103 colorectal, 3621 breast, 3620 cervical participation, % | Finnish Cancer Registry |
| Primary care access | 6411 GP appointments that waited over 7 days, % | THL |
| Practical barriers | 5201 travel connections, 5208 client fees hampered care, % | THL |
| Referral handling | 13 specialist referrals processed within 3 days, % | THL |
| Survival | 3625 breast, 3627 bowel five-year relative survival, % | Finnish Cancer Registry |

`GET /demo/equity/data` (authenticated) returns the figures. The server refreshes
from the THL Sotkanet open API at most every six hours and uses the newest year that
has a national value. If Sotkanet is slow, down or returns fewer counties than
expected, the committed snapshot `apps/crm-web/src/lib/pathway-snapshot.json` is
served and the page says "Saved copy from <date>". The page renders from the snapshot
first, so it never waits on the live source.

- `pnpm pathway:snapshot` regenerates the snapshot.
- `EDGECARE_PUBLIC_DATA=snapshot` turns live refresh off (used by the browser tests).

Only public aggregate statistics are requested. Nothing about referrals is sent to
Sotkanet, and no demographic or socioeconomic attribute is inferred for anyone.

## Reading the numbers honestly

- These are county averages. They cannot show differences between groups inside a
  county, which is where much of the inequality in the challenge brief sits.
- Stages use different populations and years; the overview is not a patient funnel.
- Referral handling covers all specialties, and the barrier survey covers all health
  services. Neither is cancer-specific.
- Survival is the Goal 3 measure shown (National Cancer Strategy 2026–2035, "equal
  and effective cancer care"). It reflects diagnoses from earlier years, and small
  counties move several points between years; counties under 100,000 people carry a
  caution. A 1-point flag on survival is a prompt to look, not a finding.
- The screening slider is arithmetic on the published invitation round (invited is
  estimated from the published count and rate). It is not a forecast of an effect.
- Pilot targets are proposals, not effect estimates or national standards.

`src/lib/pathway.ts` holds the stage definitions, ranking and thresholds;
`src/lib/equity-actions.ts` holds the plans and the brief. All calculations are
deterministic.

## Evidence and AI

Reviewed snapshots:
- CPSTF, *Patient navigation services to increase breast, cervical and colorectal
  cancer screenings and advance health equity*, published 2024-05-17 (US evidence).
- WHO, *Guide to cancer early diagnosis*, published 2017-02-16.
- Ministry of Social Affairs and Health, *National Cancer Strategy 2026–2035*
  (English edition), 2025-12-17.

**Explain with AI** calls the authenticated `POST /demo/equity/explain` with
`{ "region": <Sotkanet region id>, "basis": "live" | "snapshot" }`. The server
rebuilds the county's pathway itself, sends the brief, the flagged stage's figures,
the plan and the one retrieved evidence snapshot, and uses the server-only
`RUNWARE_API_KEY` and `RUNWARE_MODEL`. No referral data is sent. The reply must cite
the retrieved evidence ID and may not contain any number that was not supplied;
otherwise it is rejected. Missing configuration, provider outages and rejected
output leave the data-based brief visible with an explicit error. Generated prose
still needs human review. This is curated snapshot retrieval, not live web search.

## Referral waiting clocks

The referrals page shows, for each referral, how long it has waited since it was
received, or how long it took to be verified. A strip above the filters gives the
longest and median open wait, the number open for more than 7 days, and the median
time to verification; **Longest waiting first** sorts open referrals by wait.
The 7-day review point (`src/lib/waiting.ts`) is a workspace setting for the demo,
not a clinical standard. Clocks advance with each successful poll, so they never run
ahead of the data shown.
