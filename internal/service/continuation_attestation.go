package service

import (
	"errors"
	"math"

	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"
	"github.com/sirerun/MISTT/internal/audio"
	"google.golang.org/protobuf/proto"
)

// settledCaptureContinuation attests ledger custody, not model text or semantic
// finality. In particular, silence need not produce any transcript event.
func settledCaptureContinuation(pair *activePair, cut uint64, cursors map[audio.Source]rolloverCursor) (*misttv1.CaptureContinuation, error) {
	fail := func() (*misttv1.CaptureContinuation, error) {
		return nil, errors.New("paired native continuation is not proven")
	}
	if pair == nil || !pair.syntheticRemoteEnds || !pair.remoteSettled || !pair.ready.CaptureContinuation || pair.ready.MaxActivePairs != 1 || !pair.remoteCompleted[audio.Microphone] || !pair.remoteCompleted[audio.CallAudio] || !audio.ValidUUIDText(pair.id) || !audio.ValidUUIDText(pair.nativeSessionID()) || cut == 0 || len(cursors) != 2 || pair.remoteLedgers == nil {
		return fail()
	}
	start := pair.started.GetSessionStarted()
	if start == nil || pair.started.SessionId != pair.id || start.Backend != "dgx_paired" || start.Model == "" || start.Model != pair.ready.Model || start.Language != "en" || start.SampleRateHz != audio.SampleRate || start.Channels != audio.Channels || start.Encoding != audio.Encoding || start.CaptureEpochHostNs == 0 || start.CaptureEpochHostNs != pair.epochHostNS || start.CaptureEpochUnixMs <= 0 || start.CaptureEpochUnixMs != pair.epochUnixMS || pair.nativeStarted.CaptureEpochHostNS != pair.epochHostNS || pair.nativeStarted.CaptureEpochUnixMS != pair.epochUnixMS || !pair.nativeStarted.MicrophoneReady || !pair.nativeStarted.CallAudioReady || len(start.Sources) != 2 || len(pair.nativeStarted.Sources) != 2 {
		return fail()
	}
	if pair.epochHostNS > math.MaxUint64-cut || pair.epochUnixMS > math.MaxInt64-int64(cut/1_000_000) {
		return fail()
	}
	proof := &misttv1.CaptureContinuation{Version: 1, PreviousSessionId: pair.id, NativeSessionId: pair.nativeSessionID(), CutoverOffsetNs: cut}
	for i, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		expected := &misttv1.SourceFormat{Source: string(source), SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}
		nativeFormat := pair.nativeStarted.Sources[i]
		if !proto.Equal(start.Sources[i], expected) || nativeFormat.Source != source || nativeFormat.SampleRateHz != audio.SampleRate || nativeFormat.Channels != audio.Channels || nativeFormat.Encoding != audio.Encoding {
			return fail()
		}
		old := pair.remoteLedgers[source]
		native := pair.ledgers[source]
		next, ok := cursors[source]
		if old == nil || native == nil || old.frames == 0 || old.firstSample != 0 || native.frames == 0 || native.ended || !ok || next.Sequence == 0 || next.Sequence > native.nextSequence || next.StartSample >= native.nextSample || next.CaptureOffsetNS < cut || next.CaptureOffsetNS-cut >= audio.SampleNS || pair.epochHostNS > math.MaxUint64-next.CaptureOffsetNS || pair.epochUnixMS > math.MaxInt64-int64(next.CaptureOffsetNS/1_000_000) {
			return fail()
		}
		origin, hasOrigin := pair.remoteOrigins[source]
		if pair.remoteOffsetNS > 0 && !hasOrigin {
			return fail()
		}
		if old.nextSample > math.MaxUint64-origin.StartSample || old.nextSample > math.MaxUint64/audio.SampleNS || old.firstOffset > math.MaxUint64-old.nextSample*audio.SampleNS {
			return fail()
		}
		end := old.firstOffset + old.nextSample*audio.SampleNS
		if end > math.MaxUint64-pair.remoteOffsetNS || origin.StartSample+old.nextSample != next.StartSample || pair.remoteOffsetNS+end != next.CaptureOffsetNS {
			return fail()
		}
		if next.StartSample < native.firstSample || next.StartSample-native.firstSample > math.MaxUint64/audio.SampleNS {
			return fail()
		}
		delta := (next.StartSample - native.firstSample) * audio.SampleNS
		if native.firstOffset > math.MaxUint64-delta || native.firstOffset+delta != next.CaptureOffsetNS {
			return fail()
		}
		proof.Sources = append(proof.Sources, &misttv1.CaptureSourceOrigin{Source: string(source), StartSample: next.StartSample, CaptureOffsetNs: next.CaptureOffsetNS})
	}
	return proof, nil
}
