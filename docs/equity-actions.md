# CRM equity actions

Open the authenticated CRM and select **Equity actions** in the sidebar.

Three reviewed action plans cover screening participation, referral acknowledgment,
and appointment attendance. Every card includes an accountable owner, implementation
steps, proposed resources, a measure, a pilot target, a dated source and evidence limits.
Apple-style system typography, 17px body text, generous spacing, restrained rounded
surfaces and accessible controls are combined with AstraZeneca mulberry/magenta/graphite,
as directed by `docs/design/apple-styling.md`.

## Data honesty

The current CRM does **not** collect the events or denominators necessary to detect
these gaps. Counts are explicit synthetic aggregate scenarios, separate from referral
records and their open/spent states. The scenario selector demonstrates gap detection
and a no-gap state; it does not model an intervention's effect.

`src/lib/equity-actions.ts` computes percentage-point differences deterministically.
No demographic or socioeconomic attributes are inferred. Before connecting real data,
define cohort eligibility, period, missing-data handling, small-cell suppression,
uncertainty and the official Goal 3 indicator with mentors/regional stakeholders.

The team's shared research conversation
(`https://claude.ai/share/3b5beb9a-b963-4e04-ae5b-ef4a22c140c3`) informs the data-readiness
panel: recommendations first, outcomes as the Goal 3 anchor, screening as supporting
detection work, and the cancer-pathway "missing middle" made explicit. The linked
conversation is planning context, not a verified primary statistical source. Its
numerical claims have not been copied. Finnish Cancer Registry, THL Sotkanet and
Statistics Finland are linked for subsequent source validation and cohort selection.

## Evidence and AI

Reviewed snapshots:
- WHO, *Guide to cancer early diagnosis*, published 2017-02-16.
- CPSTF, *Patient navigation services to increase breast, cervical and colorectal
  cancer screenings and advance health equity*, statement published 2024-05-17.

US screening navigation evidence does not establish a Finnish effect on appointment
attendance. The acknowledgment queue is a proposed implementation of WHO pathway
guidance, not a WHO-tested queue intervention. Targets are proposed pilot aspirations,
not effect estimates or national clinical standards.

**Explain this plan with AI** calls the authenticated `POST /demo/equity/explain`
endpoint. It retrieves the selected reviewed snapshot and uses server-only
`RUNWARE_API_KEY` and `RUNWARE_MODEL` settings already used by the voice backend.
No patient data is sent. Structured output must reference the retrieved evidence ID;
source URLs, calculations, actions and targets remain fixed outside the model.
Generated prose still requires human review. Missing configuration, provider outages
and invalid output leave the reviewed plan visible with an explicit error.
No background AI calls are made during CRM polling.

This is curated snapshot retrieval, not live web search. Nothing was deployed by
adding this feature; hosted Vercel source-upload deployment is a separate step.
