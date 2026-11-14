# Access digital twin

`/digital-twin` in the CRM is a 3D simulation of where primary care is delivered in Helsinki. It suggests where **one extra clinician, one on-site interpreter or one mobile clinic** would improve access most. It models places and services, never people: no patient, referral, address, nationality or immigration status is used or shown.

## What it models

| Model input | Source | Status |
| --- | --- | --- |
| Residents per 250 m cell | HSY population grid, 31.12.2024 (CC BY 4.0) | Published |
| Share of residents with a mother tongue other than Finnish, Swedish or Sami, and share aged 75+, per sub-district | City of Helsinki Aluesarjat, 2025 (CC BY 4.0) | Published |
| Health stations, weekly opening hours (8–16 vs evening, early and Saturday), wheelchair accessibility shortcomings | Helsinki Service Map (CC BY 4.0) | Published |
| Public libraries as candidate mobile-clinic stops | Helsinki Service Map (CC BY 4.0) | Published |
| Clinicians per station, interpreting coverage, share needing evening hours, absence rate, mobile-clinic hours | — | **Planning assumptions**, set on the page |
| Travel times | Straight-line distance × detour factor: walking, step-free walking, or public transport plus a wait | **Estimate**, not a journey planner |

Two demand groups use area-level proxies. "May need an interpreter" is the sub-district share of residents by mother tongue; many of them need no interpreter. "Needs a step-free route" is the share aged 75+.

## Method

Access uses the enhanced two-step floating catchment area method (E2SFCA, Luo & Qi 2009) with a 40-minute Gaussian travel-time decay:

1. Each station's weekly appointment hours are divided by every resident who can reach it, weighted by travel time.
2. Each cell sums the stations it can reach. Each group reaches only the share that suits it: interpreting coverage for the language group, the station's step-free rating and slower routes for the 75+ group, and the share of hours outside 8–16 for the evening group.

The **access gap** is Σ residents × how far their access falls below the Helsinki average, summed over the four groups.

**Scenarios.** Each run simulates 120 weeks. Each week varies clinician absence, sub-district demand (±8%), travel speed (−10% to +25%) and a 10% chance that one station closes unexpectedly. Within each week, every possible placement is scored: each open station for a clinician or an interpreter, and each library for a mobile clinic. That is about 11,000 scenarios, run in the browser in about a second. All placements in a week share the same random draw. The run is seeded, so the same settings give the same answer. Each suggestion shows:
- the mean share of the access gap it closes;
- the 5–95% range across simulated weeks;
- how often it was the best choice.

**Disruptions** you can switch on: a public transport strike (walking only), phone and video interpreting being unavailable, or one health station being closed.

## Limits

- Travel times ignore the street network and water. Trips to and across islands are understated.
- In E2SFCA a new site does not draw demand away from other sites' ratios. A gain is the direct effect of the added capacity.
- Clinician numbers and interpreting coverage are not published. Treat the results as a ranking of places to look at with local teams, not a forecast.

## Refreshing the data

```sh
pnpm twin:snapshot   # rewrites apps/crm-web/src/lib/twin-snapshot.json from the public APIs
```

The engine is `apps/crm-web/src/lib/twin.ts`. Its tests are in `apps/crm-web/tests/twin.test.ts`. They check, among other things, that the fast per-candidate estimate equals a full recompute and that the snapshot holds only aggregate fields.
