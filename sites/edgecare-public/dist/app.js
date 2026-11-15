(() => {
  'use strict';
  const scriptUrl = document.currentScript.src;
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
    ['A conversation on your terms.', 'Use structured questions or a consent-based voice conversation in a supported language. A private community setting makes room for the first step.', 'The synthetic prototype includes six interface languages: English, Finnish, Somali, Arabic, Ukrainian and Nepali. Structured forms work offline; voice requires a connection.', 'Synthetic prototype'],
    ['A history you can check.', 'Review what was captured, correct the details and decide what to share with the receiving clinician.', 'The prototype creates an English clinical summary. Clinical translation, completeness and accessibility require language-specific evaluation.', 'Prototype · Validation needed'],
    ['A clearer next action.', 'In the proposed pilot, a clinician reviews the history and decides the appropriate next step before guidance reaches the participant.', 'AI urgency recommendations would be assessed separately against an independent clinical judgement. They would not determine care autonomously.', 'Proposed supervised pilot'],
    ['Context for the next clinician.', 'The submitted symptom history can continue into the consultation through an authorised referral workflow.', 'The synthetic demo includes a patient referral wallet, clinician verification and a web workspace. Production integration, access recovery and identity assurance remain to be developed and validated.', 'Synthetic handoff · Future integration']
  ];
  const shots = [
    ['assets/kiosk-form.jpg', 'Kiosk symptom form with six concern options, “A persistent cough” selected, duration and impact pickers, read-aloud and on-device dictation.', 'Kiosk · Structured form, with a voice conversation tab beside it.'],
    ['assets/kiosk-question.jpg', 'Kiosk follow-up question “Are you bleeding heavily right now, or is the bleeding making you feel faint or collapse?” with Yes, No and I’m not sure answers.', 'Kiosk · One question at a time, with safety questions asked first.'],
    ['assets/kiosk-guidance.jpg', 'Kiosk “Your next step” screen advising a clinician review and stating the guidance cannot diagnose or rule out cancer, with a button to create a private referral.', 'Kiosk · Prototype guidance. In the pilot, a clinician would review it first.'],
    ['assets/doctor-verify.jpg', 'Doctor iPhone app “Verify referral” screen for a synthetic dermatology referral, with instructions in Somali and code boxes for the patient.', 'Doctor app · The referral is verified at the visit with the patient’s code and signature.']
  ];
  const flowButtons = [...document.querySelectorAll('[data-flow]')];
  function selectFlow(index, focus = false) {
    flowButtons.forEach((button, i) => { button.setAttribute('aria-selected', String(i === index)); button.tabIndex = i === index ? 0 : -1; });
    const values = flows[index];
    ['flow-title', 'flow-description', 'flow-detail', 'flow-status'].forEach((id, i) => { document.getElementById(id).textContent = values[i]; });
    document.getElementById('flow-number').textContent = `0${index + 1}`;
    const image = document.getElementById('flow-image');
    if (image) {
      const [src, alt, caption] = shots[index];
      image.src = new URL(src, scriptUrl).href; image.alt = alt;
      image.closest('.flow-shot')?.classList.toggle('is-phone', src.includes('doctor-'));
      document.getElementById('flow-caption').textContent = caption;
    }
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
