# Delivery evidence

Updated 2026-10-04 UTC. Passing a supporting check does not satisfy the paired MVP, release or installed-update gates.

| Gate | Status | Evidence and limits |
|---|---|---|
| Single-source DGX qualification | Passed and landed | [Bounded qualification](qualification/vibevoice-streaming-asr.md), PR #1 landed `4255bd2362e6184e0e0687ea149db4815d8106a8`; synthetic paced speech, not native or paired acceptance |
| Paired control/schema consistency | Supporting checks passed | Draft at `8ac2ef286ed62cd14931a122bbb6291e98d3965b`: 15 examples, EOF/conflict positive/negative shapes and independent source/time audit; numeric deadlines remain proposed |
| PCM/IPC/clock fixtures | Supporting checks passed | [Golden vectors](contracts/fixtures/paired-v1.json), [21 negative/boundary cases](contracts/fixtures/paired-v1-negative.json); synthetic reference checks, not product decoder tests |
| Native preflight build and fixtures | Local supporting checks passed | Worker checkpoint `77a1515c32c5b4e0f64d19b9c31efab9df1175f3`, integrated as `4bf6897`: 25 arm64 Swift tests passed on Xcode 27.0 / Swift 6.4, including cutoff, clock, PCM and owned-helper watchdog fixtures. Ad-hoc app packaging and strict signature verification passed. The prior fractional-cutoff failure is preserved in the development log. Tests are not hardware proof. CI run 37179186700 at `941bde0` did not start: GitHub account billing lock (zero runner steps), so no CI build/test evidence |
| Follow-up native preflight code | Runtime verification pending | Helper ownership, bounded conversion fixtures, watchdog teardown, sticky single-use gates, cancellation and post-resource identity checks are integrated. At `034c164`, whole microphone callback activity is counted with C11 atomics, replacing a macOS 15-only Swift atomic API to preserve the 14.2 baseline. Independent source review found the earlier lifecycle fixes present; converter numeric boundary fixes and revised-head review are pending. These changes have not compiled/tested together; local load remains above the build threshold |
| Native permission/target/signal/clock/closure | Corrected app opens; acceptance pending | NPF-005 fixed at native `745553b` (integrated `13374fe`), 26 tests pass and corrected app opens. Start fails closed because TikTok's main bundle has no HAL object. Local test-tone playback makes its bundleless media server's HAL output active; explicit owner/helper validation is being implemented. No permissions or captured-signal proof yet. Both grants and denial behavior, unrelated-app exclusion, cutoff/teardown/owner-loss and timing still need hardware evidence |
| Paired gateway and inference | Pending | CPU resampling/window/fairness reference probe passed six cases; actual production gateway and simultaneous model contexts not qualified |
| Integrated native MVP with three clients | Pending | T2.5 depends on native, relay, gateway and paired-inference implementation/acceptance |
| Independent MVP review | Pending | Exact candidate PR/base/head must satisfy T2.5 before T2.6 |
| MVP merge and landed verification | Pending | T2.7/T2.8 remain blocked |
| Signed Homebrew release | Pending | Developer ID Application and notarization not provisioned; no release/cask published |
| Installed automatic update | Pending | No installed MISTT or signed A-to-B transition tested |

The scoped native CI probe neither captures devices nor deploys inference. An ad-hoc probe signature does not establish Developer ID permission continuity or release readiness.

The physical test setup now routes output to connected headphones and retains the webcam microphone, verified through macOS audio-device inventory. This establishes routing only; no captured audio or per-app exclusion is proven. Scalar energy summaries are diagnostic and cannot independently prove exact cutoff under concurrent closure.
