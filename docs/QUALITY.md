# Delivery evidence

Updated 2026-10-04 UTC. Passing a supporting check does not satisfy the paired MVP, release or installed-update gates.

| Gate | Status | Evidence and limits |
|---|---|---|
| Single-source DGX qualification | Passed and landed | [Bounded qualification](qualification/vibevoice-streaming-asr.md), PR #1 landed `4255bd2362e6184e0e0687ea149db4815d8106a8`; synthetic paced speech, not native or paired acceptance |
| Paired control/schema consistency | Supporting checks passed | Draft at `8ac2ef286ed62cd14931a122bbb6291e98d3965b`: 15 examples, EOF/conflict positive/negative shapes and independent source/time audit; numeric deadlines remain proposed |
| PCM/IPC/clock fixtures | Supporting checks passed | [Golden vectors](contracts/fixtures/paired-v1.json), [21 negative/boundary cases](contracts/fixtures/paired-v1-negative.json); synthetic reference checks, not product decoder tests |
| Native preflight build and fixtures | Pending | Initial prototype compiler errors corrected in source; revised snapshot has not compiled. Shared-host build admission unavailable; capture-free CI being prepared |
| Native permission/target/signal/clock/closure | Pending | Both grants and denial behavior, actual TikTok/helper audio producer, unrelated-app exclusion, cutoff/teardown/owner-loss and timing need hardware evidence |
| Paired gateway and inference | Pending | CPU resampling/window/fairness reference probe passed six cases; actual production gateway and simultaneous model contexts not qualified |
| Integrated native MVP with three clients | Pending | T2.5 depends on native, relay, gateway and paired-inference implementation/acceptance |
| Independent MVP review | Pending | Exact candidate PR/base/head must satisfy T2.5 before T2.6 |
| MVP merge and landed verification | Pending | T2.7/T2.8 remain blocked |
| Signed Homebrew release | Pending | Developer ID Application and notarization not provisioned; no release/cask published |
| Installed automatic update | Pending | No installed MISTT or signed A-to-B transition tested |

The scoped native CI probe neither captures devices nor deploys inference. An ad-hoc probe signature does not establish Developer ID permission continuity or release readiness.
