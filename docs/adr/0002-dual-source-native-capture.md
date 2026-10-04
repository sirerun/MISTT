# ADR 0002: Separate native microphone and app-playback capture

Status: Accepted product requirements; proposed capture/IPC implementation boundary, subject to native spike. Supersedes ADR 0001's Go/malgo capture ownership paragraph, not its Homebrew/Sparkle direction. Date: 2026-10-04 UTC.

## Decision

The user requires both microphone and selected-app call playback to remain separate timestamped streams, transcript provenance labels `microphone`/`call_audio`, and one mute that stops both. Use native Core Audio process taps for a specific app output, never global system-audio capture.

Propose that the signed native app process own both capture sources, their two permission surfaces, callback host timestamps and atomic capture gate. Go owns local subscriptions, lifecycle authority, admission/remote transport and transcript fanout. Native capture has no recognition models. Replace the prior microphone-only Go/malgo capture path and line-only control bridge with bounded framed native audio/control IPC.

Minimum macOS 14.2. Inclusion-only private tap over explicitly resolved process object IDs, private aggregate device, and unmuted playback behavior. Use portable HAL process resolution at this baseline; SDK `bundleIDs` and restore APIs are macOS 26-only. Missing or changed identity fails closed instead of selecting another app/all-system output. The first acceptance app is TikTok LIVE Studio (installed version observed as 1.36.4), bundle ID `com.tiktok.livestudio.desktop`. Its actual audio-producing helper/process identities must be qualified explicitly; installation alone does not prove tap capture. Use local playback/preview without starting a public LIVE broadcast. App/helper selection is external configuration; any browser tap may capture other audio in the targeted browser, not just one tab.

Convert valid Core Audio host ticks with `AudioConvertHostTimeToNanos` for epochs, anchors and cutoff comparisons; wire `_ns` fields never contain raw ticks. Each source keeps its own samples, clock mapping, converter, sequence, queue, ASR KV context and transcript state. Share model weights; paired admission and fair bounded serialized inference. Mute closes both sample gates/I/O at a common host-time cutoff before source-specific EOF/final drain. Failure of either source ends the pair and returns Muted; recovery requires explicit unmute and a fresh pair.

## Consequences and required evidence

Local test-tone playback identified TikTok's bundleless `MediaSDK_Server` as an active HAL output producer while its named Electron helper remained idle. The owner app need not have a HAL object. Explicit external configuration may select this one vetted app-relative executable; native must also validate live owner/helper signatures against the fixed team/signing identifiers, exact canonical path, direct ancestry, same user and process-start/HAL incarnations. A path alone or a wildcard descendant match never authorizes capture. See the [paired contract](../contracts/desktop-dgx-v1.md) for the qualification tuple. Inventory correlation is supporting evidence; actual signal, exclusion and loss acceptance remain open.

Native spike must establish mic/system-audio permission attribution and denial/revocation behavior; exact app/helper targeting; tap teardown leaving call playback intact; callback clock validity/drift; and mute cutoff on both sources. Lack of one stream cannot silently reduce scope to microphone-only recording. Acoustic speaker leakage into the microphone remains possible; source labels express provenance, not diarization or echo cancellation.

The existing single-stream DGX qualification remains valid as historical inference evidence. It does not establish two-source latency, memory/context capacity, atomic admission or fair scheduling. Repeat paced independent fixtures simultaneously; verify distinct transcripts, capture-derived timestamps and independent final tails before accepting the new MVP.

No new capture implementation, model deployment, build or permission grant is performed by this planning revision. Paused one-source worker files remain checkpoints for selective reuse, not accepted candidates.

References: [RFC](../rfc/rfc-0001.md), [wire/IPC contract](../contracts/desktop-dgx-v1.md), [Apple tap guide](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps), [CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription), [AudioTimeStamp](https://developer.apple.com/documentation/coreaudiotypes/audiotimestamp).
