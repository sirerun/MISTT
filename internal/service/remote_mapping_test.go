package service

import (
	"reflect"
	"testing"

	"github.com/sirerun/MISTT/internal/audio"
)

type mappingSession struct {
	inertSession
	frames []audio.Frame
}

func (s *mappingSession) QueueFrame(f audio.Frame) error {
	f.Samples = append([]int16(nil), f.Samples...)
	s.frames = append(s.frames, f)
	return nil
}

func TestRemoteMappingSplitsNativeFrameWithoutDoubleAdvancement(t *testing.T) {
	native := "00112233-4455-6677-8899-aabbccddeeff"
	successor := "00112233-4455-6677-8899-aabbccddeeaa"
	for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		before, after := &mappingSession{}, &mappingSession{}
		ledger := &sourceLedger{nextSequence: 10, nextSample: 100, frames: 10, samples: 100}
		old := &activePair{id: native, nativeID: native, remote: before, epochHostNS: 1, ledgers: map[audio.Source]*sourceLedger{source: ledger}, remoteLedgers: map[audio.Source]*sourceLedger{source: {nextSequence: 10, nextSample: 100, frames: 10, samples: 100}}}
		f := audio.Frame{SessionID: mustUUID(native), Source: source, Sequence: 11, StartSample: 100, CaptureOffsetNS: 100 * audio.SampleNS, Samples: []int16{1, 2, 3, 4}}
		if err := validateNativeFrame(old, f, nil); err != nil {
			t.Fatal(err)
		}
		left, right, err := splitRolloverFrame(f, 102*audio.SampleNS)
		if err != nil {
			t.Fatal(err)
		}
		if err = queueRemoteFrame(old, *left); err != nil {
			t.Fatal(err)
		}
		next := &activePair{id: successor, nativeID: native, remote: after, epochHostNS: 1, ledgers: old.ledgers, remoteOffsetNS: 102 * audio.SampleNS, remoteOrigins: map[audio.Source]rolloverCursor{source: {Sequence: 11, StartSample: 102, CaptureOffsetNS: 102 * audio.SampleNS}}}
		if err = queueRemoteFrame(next, *right); err != nil {
			t.Fatal(err)
		}
		f.Sequence = 12
		f.StartSample = 104
		f.CaptureOffsetNS = 104 * audio.SampleNS
		f.Samples = []int16{5, 6}
		svc := &Service{}
		if err = svc.acceptFrame(next, f, nil); err != nil {
			t.Fatal(err)
		}
		got := append(append([]int16{}, before.frames[0].Samples...), after.frames[0].Samples...)
		got = append(got, after.frames[1].Samples...)
		if !reflect.DeepEqual(got, []int16{1, 2, 3, 4, 5, 6}) {
			t.Fatal("lost or replayed boundary speech")
		}
		if ledger.nextSequence != 12 || ledger.nextSample != 106 || after.frames[0].SessionID != mustUUID(successor) || after.frames[0].Sequence != 1 || after.frames[0].StartSample != 0 || after.frames[1].StartSample != 2 {
			t.Fatal("native and remote ledgers conflated")
		}
	}
}
