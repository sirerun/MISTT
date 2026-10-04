# ADR 0005: Greeter consumer boundary

Status: Technical peer agreement concluded on 2026-10-04; Greeter founder product/authority/privacy/model decisions remain open. This records the MISTT-side recommendation, not approval of Greeter implementation, final packaging or live operations.

## Agreed technical recommendation

Greeter consumes separately installed, independently updated MISTT through the owner-qualified loopback `mistt.v1` gRPC contract. MISTT owns native microphone and inclusion-only selected-app playback capture, authoritative mute/status, paired session lifecycle and source-labeled transport to the owner-controlled remote ASR gateway. Neither desktop app runs a recognition model. Greeter owns bounded transcript consumption, client/proto pinning and compatibility, reconnect/deduplication, session/presence interpretation, response/TTS output policy and no-feedback acceptance. Comuse separately owns semantic computer-use targeting/enforcement; Greeter's trusted host owns its output/action authority. No observer/model/chat content can grant capture, public output or desktop-action authority.

The candidate contract exposes bidirectional `Mistt.StreamTranscription`, `WatchStatus` and revision-checked `SetMuted`. Canceling a subscription affects that consumer; it is not an all-consumer mute. Greeter emergency stop suppresses its own new outputs/actions and cancels its subscription. All-sources mute requires explicit operator authority through the trusted host and revision-checked `SetMuted`; the revision check prevents stale control and is not a substitute for authority. Restart/update/disconnect does not authorize unmute, replay pending outputs or treat a gap as new speech.

`microphone` and `call_audio` describe provenance, not named/diarized guests. Selected-app playback can mix participants. Greeter independently qualifies identity/presence signals and output routing that avoids TTS feedback into captured sources; no echo-cancellation guarantee is inferred.

## Qualification and ownership

Source/fixture readiness is not landed API, native consent/audio, deployed gateway, signed installation or working automatic-update acceptance. Greeter integration waits for exact landed dependency artifacts and real target-platform/audio/no-feedback evidence. The published proto and representative generated consumer must be qualified across MISTT's A-to-B transition: cancellation, partial/final/gap/stopped events, status/counts and explicit reconnect, without replaying unmute.

These consequences refine existing MISTT T2.16/T2.6/T4.4 acceptance, not a second scheduler or an implicit Greeter task. MISTT deployment remains independently scoped. Greeter founder questions and RFC finalization belong to its repository; the editor concluded the peer subthread while leaving those questions and RFC revision open. Agreed decisions, not the discussion channel itself, are the durable architecture record.
