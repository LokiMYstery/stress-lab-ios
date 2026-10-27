# Design

## Source of truth
- Status: Active — experimental internal tool, refreshed 2026-09-23.
- Primary surfaces: standalone iPhone dashboard, records, parameters, source settings.
- Evidence: approved Stress Lab plan and paired September 21–23 StressWatch/Stress Lab screenshots (`IMG_7138`–`IMG_7143`). Parent DESIGN.md describes the separate music product; its dark player styling does not apply here.

## Brand
- Neutral, precise, approachable. Explain provenance; never diagnose or claim proprietary algorithm parity.
- No StressWatch logos, illustrations, subscriptions or marketing UI.

## Product goals
- Compare real RMSSD measurements and experimental pressure trends with another app on the same phone.
- Expose timestamps, data gaps, source identity, baseline readiness and parameter versions.
- Non-goals: production Agent integration, cloud storage, Watch app, medical validation.

## Personas and jobs
- Product owner and engineers inspecting their own consented HealthKit data.
- Switch between apps, match a time, inspect inputs, change parameters, replay a day.

## Information architecture
- One dashboard: date navigation, HRV chart, pressure chart, current reference card.
- Secondary sheets: records, parameters, settings/device/version selection.
- Settings includes opt-in health notifications for new usable HRV measurements and significant heart-rate pressure trends. Trend settings expose comparison/window lengths, score threshold and cooldown, with a diagnostic comparison. Compare stationary awake windows using one personal heart-rate baseline, independent of HRV and resting-heart-rate changes. HRV notices take priority; stable or insufficient windows never notify. Include a delayed test notice and system registration diagnostics. Tapping a notice opens its measurement day; demo records never trigger health notices.

## Design principles
- Measurement and estimation must be visually distinguishable from default.
- Missing history is empty, never an invented trace. Shared chart time axes facilitate comparison.
- Keep filtering visible; preserve rejected records in diagnostics.
- Keep V0, V1, V2 and V3 model settings selectable. V3 calibrates the HRV point score with paired user-provided values, anchors the next six-minute pressure bin to that score, then blends into the heart-rate channel. Its current version leaves a bin unscored for explicit Apple Watch heart-rate `active` metadata, but does not infer movement from steps; workout exclusions remain separate. Historical step-based versions remain available for report reproduction. Resting heart rate remains optional corroboration. Disclose the actual inputs for each selected pressure bin. Do not claim exact StressWatch parity from three days of data.
- Persist completed historical daily reports by local day, time zone, source and parameter version. Reuse them immediately when the user switches dates; the current day remains live. An explicit refresh can rebuild a past report.
- HRV chart uses a neutral line and outlined, category-colored points. A tap reveals the RMSSD, comparison basis and status. The chart also reports rejected heartbeat series, heartbeat series from other Watch sources, and SDNN samples without a matching series in the selected source.

## Visual language
- Light grouped background, white rounded cards, mint accent, blue middle-band pressure bars and outlined HRV markers with green/blue/orange/red category colors. Red means V1 reference score 81–100, not a diagnosis.
- System fonts with Dynamic Type; tabular numbers for metrics. No external assets.
- Subtle transitions; no essential animation or gradient encoding of data quality.

## Components
- SwiftUI Forms, NavigationStack, sheets and Charts; no new external design framework.
- Reusable score/provenance labels, baseline details, timestamp summaries, empty-state cards.

## Accessibility
- Text labels supplement colors; selected values remain available through the records list.
- Native focus, VoiceOver labels and controls; respect large text and reduced motion.

## Responsive behavior
- iPhone SE through Max, vertical scrolling; charts use available width without horizontal clipping.
- Touch selection with textual details; no hover-dependent interactions.

## Interaction states
- Loading: keep previous data visible and disable overlapping refresh.
- Empty: explain no readable samples, not presumed denial. V2 may show previously filtered RMSSD values but must retain data-gap and nonpositive-time safeguards. No fabricated charts.
- Error: preserve last committed snapshot and display recoverable error.
- Success: disclose last sync and sample timestamps separately.
- Disabled: future dates, unavailable source selection, invalid parameter submission.
- Offline: all computation works locally; sync still depends on Apple's device delivery.

## Content voice
- Chinese UI; short factual labels. Explicit 实验模型 / 非医疗判断 / 默认参考 / 模拟数据.
- 6分钟时间格 is not a promise of background sampling every six minutes.

## Implementation constraints
- SwiftUI, Swift Charts, HealthKit, iOS17+, no third-party dependencies or network calls.
- Demo fixture restricted to simulator/debug use and never persisted as real HealthKit data.
- Read-only authorization; protected app-private local storage excluded from backup.
- HealthKit observers are installed at application launch and await completed processing before acknowledging background delivery. Cache protection permits background access after the device's first unlock; HealthKit reads may still require unlocking. Background callbacks are system-scheduled, not a polling timer.
- Test core determinism, gaps, dates, sleep, device separation, empty and UI SE/Max layouts.

## Open questions
- Device signing and availability determine whether a real-device read can be verified during delivery.
- V0 coefficients are explicit test hypotheses. Numerical StressWatch parity requires subsequent owner comparison.
