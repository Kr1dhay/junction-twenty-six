# EDI + Gemini visual review

## Kiosk decluttering

Patient-facing kiosk pages prioritize the current question, next action, and
essential safety/consent information:

- Remove the persistent shared-demo badge and idle-timeout footer. Keep the
  imminent session-clear warning and all timeout behavior.
- Replace the large “Demo controls” toolbar label with a settings icon. Connection
  status, offline simulation, sync, and sample credentials remain in that menu.
- Keep welcome privacy information available in a collapsed disclosure. Cloud
  voice disclosure/consent stays visible before starting voice.
- Remove the repeated triage/score footnote. Simplify the fixed patient guidance
  without changing routing logic, priority metadata, sources, or emergency text.
- Do not show speech-recognition boilerplate under Read aloud. Playback progress
  and failures remain visible; the kiosk form also omits technical storage hints.
- Show OCR instructions only when letter text exists, and photo-assessment
  limitations only when adding/reviewing a skin photo, not on the empty letter page.
- Put source links in a collapsed “Sources” disclosure after the primary action.
- Hide sample-signature/code instructions on the patient-facing sealing page,
  but retain the code-loss warning and explicit acknowledgement.
- Avoid unnecessary success/sync metadata after handoff, while retaining pending
  states, failures, and recovery actions. Booking retains a concise warning that
  no real clinic appointment is reserved.

Screenshot tests navigate a synthetic intake through guidance and sealing without
submitting a referral. They check that source links remain accessible and that
112 advice remains prominent. Review builds exclude unrelated local edits and
untracked duplicate Swift files, which are preserved in the working folder.

Verification: 28 focused unit tests pass, including five-language guidance,
unchanged priority metadata, intake safety, voice orchestration, and contrast.
Screenshot navigation checks pass for welcome/form/voice readiness, privacy
disclosure access, guidance with expandable sources, referral creation, booking,
and emergency advice. Reviewed the guidance, optional-context, sealing, booking,
and welcome captures. No referral was submitted and no cloud voice consent was
granted. This cleanup pass was captured in light appearance.

**Current voice interaction:** speaker-safe, tap-only interruption supersedes the
spoken barge-in described in the historical review entries below. Microphone
transmission pauses while Edi speaks and for a 500 ms echo tail; “Speak now”
appears automatically afterward. The prominent speaking hint says “Tap the
microphone to interrupt.” No claim of hands-free Mac-speaker echo cancellation.

Speaker-safe regressions pass 55 focused tests. They verify that loud captured
audio during playback and its tail is not sent, late callbacks and pre-roll do
not leak old echo, a mic tap stops playback, local/remote interruption can rearm,
stopping during the tail cannot reopen input, and multiple follow-up questions
still use one continuous capture engine. The room-noise estimate is retained.
The five-state screenshot test passes, including the new tail-hold state and an
assertion for the tap-only speaking hint. The speaking/settling captures were
reviewed locally. A real Mac-speaker retest is still required after installation.

## Repeatable feedback loop

1. Build the merged branch and capture the installed UI before editing.
2. Review hierarchy, control visibility, clipping, contrast and language direction.
3. Change the smallest shared component that addresses the finding.
4. Rebuild, capture the same screen/state, and compare.
5. Run visual navigation tests and contrast/copy regressions before committing.

The `EdgeCareDesignReview` Xcode scheme captures welcome, structured intake,
voice-ready, accessibility-size text, and Arabic welcome screens as XCTest
attachments. It does not grant voice consent, capture microphone audio, submit
referrals, or clear installed data. The Read aloud regression does play an Apple
speech prompt and then stops it. Its launch environment uses connected mode but no patient
credentials. Relaunch the installed apps with the hosted-connection script after
the review to restore normal demo settings.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
xcodegen generate
xcodebuild -project EdgeCare.xcodeproj -scheme EdgeCareDesignReview \
  -destination 'id=YOUR_KIOSK_SIMULATOR' -derivedDataPath build \
  -parallel-testing-enabled NO -resultBundlePath artifacts/edi-review.xcresult test
xcrun xcresulttool export attachments --path artifacts/edi-review.xcresult \
  --output-path artifacts/edi-review-screenshots
```

Use `xcrun simctl ui YOUR_KIOSK_SIMULATOR appearance dark` and a new result bundle
to repeat in dark mode; restore the previous appearance afterward. Screenshots
remain local review artifacts rather than being committed with patient content.

## First-pass findings and changes

- The unbounded transcript pushes voice controls out of reach: use a bounded,
  independently scrolling transcript with differentiated patient/assistant bubbles.
- The ready/connecting/listening/processing states need a clear control area:
  group status and primary action, show progress only while connecting/thinking,
  and replace the generic “Working privately” processing label.
- Keep an explicit interrupt control as a fallback for noisy speaker routes.
  This does not establish reliable hands-free echo cancellation.
- Group consent and disclosure separately from conversation controls; keep the
  optional text composer collapsed until needed.
- Do not show empty clinical profile rows after a greeting. Display a profile
  card only after facts exist, with localized placeholders for missing fields.
- The EDI theme forced light mode: use appearance-aware surfaces and readable
  accent text while retaining the mulberry primary button and Edi artwork.
- Honor Reduce Motion for button scaling as well as the animated avatar.
- “Connected demo · queued offline” is ambiguous: label the configured shared
  backend without claiming live reachability or implying everything is queued.

## Voice verification boundary

Mac speaker playback was recorded back as patient speech during the live test.
The current safety bound pauses after four local interruptions within eight
seconds instead of allowing indefinite repetition. Headphones/closer input are
recommended in that case. Do not describe the speaker-route barge-in issue as
resolved solely because visual or deterministic tests pass.

## Screenshot review log

### Pass 1 — actual simulator captures

Captured the original installed kiosk and doctor screens, then ran the merged
theme's first screenshot suite. All three visual-navigation tests passed and
exported five screenshots: welcome, form, voice ready, accessibility welcome,
and Arabic welcome.

Findings from the images, rather than just source inspection:

- At accessibility XXXL text size, the two-column welcome layout reserved a
  mostly empty avatar column while text became a narrow, very tall column.
  **Iteration:** use a single full-width column at accessibility sizes and
  compact widths, with a smaller decorative Edi.
- The connection/language row used a single horizontal line even when its text
  could no longer fit. **Iteration:** use a vertical fallback at large sizes.
- Secondary welcome actions need the same reflow. **Iteration:** stack them at
  accessibility sizes and compact widths.
- The iPhone doctor screen repeated brand, heading and disclosure in separate
  groups, consuming space before the lookup form. **Iteration:** combine them
  into one compact introduction card; preserve the clinical limitation notice.

The second pass repeats light/dark, portrait, Arabic and accessibility captures
and verifies that the primary welcome action can be reached by scrolling.
Theme body/accent contrast tests pass at a minimum 4.5:1 in both appearances.

### Pass 2 — verify the reflow, then inspect the controls

All four light-mode screenshot tests passed, including portrait and reachable
accessibility actions. The full-width accessibility text now uses the available
screen width. However, its language grid still used a fixed minimum column width:
the screenshots showed “English” and other labels splitting into vertical pills.
**Iteration:** use full-width language rows at accessibility sizes and add a
geometry assertion preventing tall/narrow choice controls.

The Arabic and portrait captures also exposed the waving avatar's fingertips
being clipped by its drawing viewport. **Iteration:** widen the vector-art
viewport to contain the complete animated arm.

The doctor before/after capture confirms the compact introduction moves lookup
and referral content up the screen; a separate dark capture verifies appearance.
The combined kiosk run timed out during its dark pass after the light pass
succeeded; repeat dark verification independently, with its own result bundle.

### Pass 3 — accessibility recapture

The targeted accessibility screenshot test passed. The recaptured language
choices show complete names on full-width rows, and the primary action remains
reachable by scrolling. The final suite also asserts a wide row aspect ratio so
the vertical-pill regression is caught automatically.

The focused unit run passes 44 tests covering theme contrast, translated controls,
intake safety, Gemini input/interruption behavior, audio callback isolation,
feedback-loop bounds, and storage migration. These do not replace the screenshot
review or the outstanding real-acoustic interruption test.

### Final verification

The independent dark-mode rerun passed all four UI tests, including the new
language-row geometry assertion, and exported eight screenshots. Reviewed its
voice-ready and Arabic welcome captures alongside the light-mode captures.
The expanded Edi viewport no longer clips the waving arm in the reviewed image.
The doctor build also succeeded; its light/dark before/after captures were
reviewed separately. Restored both simulators to their original light appearance.

A local self-contained HTML gallery combines the actual before/after captures
and is shown in the Review pane. It is intentionally not committed. The committed
scheme, tests and this review log provide the repeatable feedback loop.

## Full-screen voice follow-up

The embedded active-voice card is superseded by a full-screen stage with a small
Back control, prominent state heading, 192-point microphone, and latest dialogue.
The setup microphone is 184 points. Consent remains explicit before starting.
Connecting uses a large Wi-Fi/progress visual rather than implying recording has
already begun. Spoken replies expose microphone interruption; ordinary listening
resumes automatically. Back stops resources while retaining the accepted profile.

First screenshot feedback:

- The large setup microphone was partly below the fold under duplicated
  intake headings and instructions. Remove the redundant voice-mode heading and
  progress bar, and place the longer instructions in “How voice works.”
- The connecting capture fills the display and keeps Back at the top. Remove a
  container-level accessibility identifier that obscured the Back button's
  identifier in automation; preserve explicit identifiers on actionable controls.
- Read aloud's simulator test passed after observing the synthesis `didStart`
  callback and stopping playback. The Mac's output is unmuted. This is playback
  startup evidence, not a measurement of intelligibility or room acoustics.

51 focused unit tests pass, including actual controller orchestration against
in-memory audio/transport doubles. They cover three consecutive question/reply
cycles without restarting capture, repeated profile tools, and replying during
old trailing silence. Playback ticket tests cover stale/duplicate completions.
Screenshot review fixtures are DEBUG-only presentation states and never grant
consent, obtain voice tokens, or start capture.

Final recapture: all four light-mode tests passed (full-screen states, portrait
accessibility, setup, and Read aloud), followed by the four-state dark-mode test.
Reviewed the exported light/dark images and regenerated the local gallery.
The speaking control retains a microphone icon to match its interruption hint;
recent dialogue scrolls independently instead of growing the whole screen.
The kiosk is restored to light appearance after review. Real acoustic
follow-up/interruption quality remains a manual check, not a screenshot result.
