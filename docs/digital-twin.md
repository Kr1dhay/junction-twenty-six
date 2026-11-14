# Access digital twin

`/digital-twin` in the CRM is a 3D simulation of public primary care across mainland Finland. It answers four plain questions on the map:
- How far is care?
- Is there enough GP capacity?
- How long are the waits?
- Who may need an interpreter?

It then tests where **one more GP, one on-site interpreter or one mobile clinic stop** would help most. It models places and services, never people: no patient, referral, address, nationality, citizenship or immigration status is used.

## Data (`pnpm twin:snapshot` rebuilds `apps/crm-web/src/lib/twin-snapshot.json`)

| What | Source |
| --- | --- |
| Residents and aged 65+ per 1 km square (summed to 2 km) | Statistics Finland population grid 2024, CC BY 4.0 |
| Foreign-language speakers by municipality (mother tongue) | Statistics Finland StatFin 11rm, CC BY 4.0 |
| GP visits per 1,000 residents; non-urgent visits waiting over 7 days | THL Sotkanet 4123 and 6411, CC BY 4.0 |
| Health stations and opening hours | Suomi.fi Service Catalogue, with gaps filled from OpenStreetMap (ODbL) |
| Villages as candidate mobile-clinic stops | OpenStreetMap (ODbL) |

Åland is excluded because ÅHS runs its health care separately. 19 municipalities have no station in either listing. Some of them do have one, so the page marks results there "check locally".

## Method

- **Travel time** is estimated from straight-line distance × 1.3 road detour:
  - by car at 30/50/70 km/h in urban/town/rural squares, plus 4 minutes;
  - without a car, the faster of walking and a bus that waits 8/25/60 minutes.

  Snow adds 30%. A bus strike leaves walking only.
- **GP capacity**: each station delivers its municipality's published GP visits for the residents who use it. A square's residents are shared across stations within 5 km of its nearest. Access is two-step floating catchment (30-minute Gaussian, car) and is reported as GP visits a year within reach per 1,000 residents.
- **Scores**:
  - GP: extra visits that reach people below the national average, weighted by how far below they are.
  - Interpreter: foreign-language speakers who use the station and live within 30 minutes.
  - Mobile clinic: people brought within 30 minutes of care. Over-65s travel without a car with the planning share set on the page.
- **Simulation**: 40 weeks, each varying road speed, demand (±8% per municipality), GP availability (±10% per station) and a 15% chance of one surprise closure. Every place is scored in every week, and the run is seeded. Results show the mean, the 5–95% range and how often each place made the top 3.
