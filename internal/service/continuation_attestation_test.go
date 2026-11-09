package service

import (
	"math"
	"testing"

	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"
	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
)

func attestationFixture() (*activePair, map[audio.Source]rolloverCursor) {
	native := "00112233-4455-6677-8899-aabbccddeeff"
	previous := "00112233-4455-6677-8899-aabbccddeeaa"
	ready := rotationReady(previous)
	ready.CaptureContinuation = true
	ready.MaxActivePairs = 1
	sources := []*misttv1.SourceFormat{{Source: "microphone", SampleRateHz: 16000, Channels: 1, Encoding: "s16le"}, {Source: "call_audio", SampleRateHz: 16000, Channels: 1, Encoding: "s16le"}}
	p := &activePair{id: previous, nativeID: native, ready: ready, epochHostNS: 99, epochUnixMS: 123000, syntheticRemoteEnds: true, remoteSettled: true, remoteCompleted: map[audio.Source]bool{audio.Microphone: true, audio.CallAudio: true}, remoteOffsetNS: 100_000_000, remoteOrigins: map[audio.Source]rolloverCursor{}, remoteLedgers: map[audio.Source]*sourceLedger{}, ledgers: map[audio.Source]*sourceLedger{}, nativeStarted: backend.CaptureStarted{RequestID: native, CaptureEpochHostNS: 99, CaptureEpochUnixMS: 123000, MicrophoneReady: true, CallAudioReady: true, Sources: []backend.SourceFormat{{Source: audio.Microphone, SampleRateHz: 16000, Channels: 1, Encoding: "s16le"}, {Source: audio.CallAudio, SampleRateHz: 16000, Channels: 1, Encoding: "s16le"}}}, started: &misttv1.StreamResponse{SessionId: previous, Payload: &misttv1.StreamResponse_SessionStarted{SessionStarted: &misttv1.SessionStarted{Backend: "dgx_paired", Model: ready.Model, Language: "en", SampleRateHz: 16000, Channels: 1, Encoding: "s16le", CaptureEpochHostNs: 99, CaptureEpochUnixMs: 123000, Sources: sources, CaptureContinuation: &misttv1.CaptureContinuation{Version: 1, PreviousSessionId: "an-earlier-generation", NativeSessionId: native}}}}}
	cursors := map[audio.Source]rolloverCursor{}
	for i, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		phase := uint64(i * 31)
		p.remoteOrigins[source] = rolloverCursor{Sequence: 2, StartSample: 1600, CaptureOffsetNS: 100_000_000 + phase}
		p.remoteLedgers[source] = &sourceLedger{nextSequence: 1, nextSample: 1600, firstOffset: phase, frames: 1, samples: 1600}
		p.ledgers[source] = &sourceLedger{nextSequence: 3, nextSample: 4800, firstOffset: phase, frames: 3, samples: 4800}
		cursors[source] = rolloverCursor{Sequence: 3, StartSample: 3200, CaptureOffsetNS: 200_000_000 + phase}
	}
	return p, cursors
}
func TestSettledAttestationUsesNativeLedgersWithoutMicrophoneText(t *testing.T) {
	p, cursors := attestationFixture() // No transcript/seen state at all, including mic.
	proof, err := settledCaptureContinuation(p, 200_000_000, cursors)
	if err != nil {
		t.Fatal(err)
	}
	if proof.Version != 1 || proof.PreviousSessionId != p.id || proof.NativeSessionId != p.nativeID || len(proof.Sources) != 2 || proof.Sources[0].Source != "microphone" || proof.Sources[1].Source != "call_audio" || proof.Sources[1].StartSample != 3200 || proof.Sources[1].CaptureOffsetNs != 200_000_031 {
		t.Fatal("wrong immediate predecessor/paired native-global origin")
	}
}
func TestAttestationRejectsUnsettledOrMismatchedNativeBoundaries(t *testing.T) {
	cases := map[string]func(*activePair, map[audio.Source]rolloverCursor){
		"unsettled":               func(p *activePair, _ map[audio.Source]rolloverCursor) { p.remoteSettled = false },
		"failed mic":              func(p *activePair, _ map[audio.Source]rolloverCursor) { p.remoteCompleted[audio.Microphone] = false },
		"legacy":                  func(p *activePair, _ map[audio.Source]rolloverCursor) { p.ready.CaptureContinuation = false },
		"missing paired origin":   func(_ *activePair, c map[audio.Source]rolloverCursor) { delete(c, audio.Microphone) },
		"native stopped":          func(p *activePair, _ map[audio.Source]rolloverCursor) { p.ledgers[audio.CallAudio].ended = true },
		"no actual successor pcm": func(p *activePair, _ map[audio.Source]rolloverCursor) { p.ledgers[audio.Microphone].nextSample = 3200 },
		"sample gap": func(_ *activePair, c map[audio.Source]rolloverCursor) {
			x := c[audio.CallAudio]
			x.StartSample++
			c[audio.CallAudio] = x
		},
		"offset gap": func(_ *activePair, c map[audio.Source]rolloverCursor) {
			x := c[audio.CallAudio]
			x.CaptureOffsetNS++
			c[audio.CallAudio] = x
		},
		"host overflow": func(p *activePair, _ map[audio.Source]rolloverCursor) {
			p.epochHostNS = math.MaxUint64
			p.nativeStarted.CaptureEpochHostNS = math.MaxUint64
			p.started.GetSessionStarted().CaptureEpochHostNs = math.MaxUint64
		},
		"wall overflow": func(p *activePair, _ map[audio.Source]rolloverCursor) {
			p.epochUnixMS = math.MaxInt64
			p.nativeStarted.CaptureEpochUnixMS = math.MaxInt64
			p.started.GetSessionStarted().CaptureEpochUnixMs = math.MaxInt64
		},
		"epoch changed": func(p *activePair, _ map[audio.Source]rolloverCursor) { p.nativeStarted.CaptureEpochHostNS++ },
		"format changed": func(p *activePair, _ map[audio.Source]rolloverCursor) {
			p.started.GetSessionStarted().Sources[0].SampleRateHz = 48000
		},
		"overflow": func(p *activePair, _ map[audio.Source]rolloverCursor) {
			p.remoteOrigins[audio.CallAudio] = rolloverCursor{StartSample: math.MaxUint64}
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			p, c := attestationFixture()
			mutate(p, c)
			if _, err := settledCaptureContinuation(p, 200_000_000, c); err == nil {
				t.Fatal("unproven continuation attested")
			}
		})
	}
}
