# Paired continuous rollover

Source custody: baseline fcf913bb3013fdd147237f7924bc99e788db98e6, tree
c10db3b8d999a424747ed0e1c96a9bab7fa4f8a8, contains relay source
7dc671074c8bfb5306e4a6264942aed61f4dfc8d unchanged. Preserve its production
background launch, approved capture targets, consent/diagnostics and rotation.
Current public main omitted these private features; rebuilding plain main would
regress the deployed composite. NativePairCapture's public watchdog changes are
already present. Public coalesced-control fix bcd49e6 was cherry-picked separately
as f5ea61c, retaining both private fatal-status and public batch regressions.

Observed upstream synthetic question tail is 2.05–3.30 seconds, warm readiness
about 306 ms. Fixed ASR windows explain this delay; no speculative client buffer
latency fix or model/provider switch is included.

`MISTT_CONTINUOUS_ROLLOVER=true` explicitly opts into paired v2 and requires
bounded budget rotation. Default remains disabled. Unsupported gateways fail
before starting native capture; no silent downgrade. The existing 120-second
remote source caps, reserved headroom, operator duration and rotation-count bounds
remain enforced. Runtime advertises one active pair: no overlapping admission.

The coordinator retains one real native generation while splitting both source
streams at an exact sample boundary. Each source keeps its clock phase. It
validates every original native frame once, independently sequences each remote
generation, and retains original sample/epoch provenance in transcript projection.
During old remote settlement and fresh readiness it owns at most eight seconds
per source (512,000 bytes paired PCM), with a ten-second deadline. Overflow,
timeout or failure stops native capture and reports failure; mute cancels retained
PCM and sends the actual stop to the original native identity. No queued replay
after cancellation and no automatic admission retry.

The separate v2 `capture_continued` handshake carries the original native
acknowledgement unchanged, successor remote identity and exact paired sample
origins. It never fabricates native capture_started/source_end proof. Gateway
terminal done now follows successful context/admission cleanup and optional
receipt finalization for both protocol versions, retaining wire shape while
closing an existing premature-done/receipt cancellation race. Only then may a
successor be opened. Queued transport PCM owns copied samples and is cleared on
completion/cancellation; error publication cannot race a closed event channel.

Synthetic tests cover queued speech across settlement/readiness, exact PCM and
sample identity, clock-phase boundaries, one admission, mute, capacity, the real
ten-second deadline, original-native stop proof, fresh-identity negotiation,
transport custody and failure/read-close races. Three-package Go race suite
(service, DGX client, config) passed before the final transport race regression;
rerun final exact source after that change. Gateway suite: 20 tests pass,
including terminal cleanup followed immediately by a fresh v2 admission and
continuation. Pure protocol tests: three pass. No model downloads are needed.

Independent component reviews found no blocking issues after exact first-frame
cursor coverage was added. Final committed service/invalidation review, final
focused checks, native/relay artifacts, DGX reviewed deployment, installation and
live long-session acceptance remain separate gates. No runtime/config/capture
changes or live ASR requests have been performed by this author lane.

Versioned public continuation attestation was added after consumer regression
proved suffix-only assessment and silent-microphone transcript absence exposed a
proof gap. SessionStarted now optionally binds immediate predecessor/original
native identity and ordered paired global origins. The producer checks successful
settlement, actual retained successor PCM, exact old accepted endpoint equality
and source clock phase before publication. No gateway Python or Swift input changed.
The Go generator include root preserves the existing descriptor path, avoiding
unrelated service-descriptor churn. Copilot must pin the published generated API
after the source guard merge; old frozen artifacts are superseded, not overwritten.
