(() => {
  'use strict';
  const toggle = document.querySelector('.nav-toggle');
  const nav = document.querySelector('.nav-links');
  toggle?.addEventListener('click', () => {
    const open = toggle.getAttribute('aria-expanded') !== 'true';
    toggle.setAttribute('aria-expanded', String(open));
    nav?.classList.toggle('is-open', open);
  });
  nav?.addEventListener('click', (event) => {
    if (event.target.closest('a')) { toggle?.setAttribute('aria-expanded', 'false'); nav.classList.remove('is-open'); }
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && toggle?.getAttribute('aria-expanded') === 'true') {
      toggle.setAttribute('aria-expanded', 'false'); nav?.classList.remove('is-open'); toggle.focus();
    }
  });

  const flows = [
    ['A conversation on your terms.', 'Use structured questions or a consent-based voice conversation in a supported language. A private community setting makes room for the first step.', 'The synthetic prototype includes five interface languages: English, Finnish, Somali, Arabic and Ukrainian. Structured forms work offline; voice requires a connection.', 'Synthetic prototype'],
    ['A history you can check.', 'Review what was captured, correct the details and decide what to share with the receiving clinician.', 'The prototype creates an English clinical summary. Clinical translation, completeness and accessibility require language-specific evaluation.', 'Prototype · Validation needed'],
    ['A clearer next action.', 'In the proposed pilot, a clinician reviews the history and decides the appropriate next step before guidance reaches the participant.', 'AI urgency recommendations would be assessed separately against an independent clinical judgement. They would not determine care autonomously.', 'Proposed supervised pilot'],
    ['Context for the next clinician.', 'The submitted symptom history can continue into the consultation through an authorised referral workflow.', 'The synthetic demo includes a patient referral wallet, clinician verification and a web workspace. Production integration, access recovery and identity assurance remain to be developed and validated.', 'Synthetic handoff · Future integration']
  ];
  const flowButtons = [...document.querySelectorAll('[data-flow]')];
  function selectFlow(index, focus = false) {
    flowButtons.forEach((button, i) => { button.setAttribute('aria-selected', String(i === index)); button.tabIndex = i === index ? 0 : -1; });
    const values = flows[index];
    ['flow-title', 'flow-description', 'flow-detail', 'flow-status'].forEach((id, i) => { document.getElementById(id).textContent = values[i]; });
    document.getElementById('flow-number').textContent = `0${index + 1}`;
    document.getElementById('flow-content').setAttribute('aria-labelledby', `flow-tab-${index}`);
    if (focus) flowButtons[index].focus();
  }
  flowButtons.forEach((button, index) => {
    button.addEventListener('click', () => selectFlow(index));
    button.addEventListener('keydown', (event) => {
      let next;
      if (event.key === 'ArrowRight') next = (index + 1) % flows.length;
      if (event.key === 'ArrowLeft') next = (index + flows.length - 1) % flows.length;
      if (event.key === 'Home') next = 0;
      if (event.key === 'End') next = flows.length - 1;
      if (next !== undefined) { event.preventDefault(); selectFlow(next, true); }
    });
  });

  const outline = 'Edge-Care pilot partnership discussion\n\nObjective: evaluate whether a private, multilingual community kiosk helps people facing access barriers reach appropriate clinical assessment.\n\nProposed scope: two sites, 160 main-study participants, eight recruitment weeks and approximately 22 weeks overall. All participant guidance would be clinician-reviewed.\n\nDiscussion: clinical and community partners; referral capacity; governance and language validation; evaluation of completed assessments, safety and costs; funding and implementation support.\n\nThis is an independent project seeking partners, not an existing AstraZeneca collaboration.';
  document.getElementById('copy-outline')?.addEventListener('click', async () => {
    const status = document.getElementById('copy-status');
    try { await navigator.clipboard.writeText(outline); status.textContent = 'Discussion outline copied. Ready to share with your team.'; }
    catch { const fallback = document.getElementById('outline-fallback'); fallback.hidden = false; fallback.value = outline; fallback.focus(); fallback.select(); status.textContent = 'Select and copy the discussion outline below.'; }
  });
})();
