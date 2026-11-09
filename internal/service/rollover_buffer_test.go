package service

import (
	"reflect"
	"testing"
	"time"

	"github.com/sirerun/MISTT/internal/audio"
)

func TestRolloverPreservesBothSourcesExactly(t *testing.T) {
	now := time.Unix(1, 0)
	native := [16]byte{1}
	remote := [16]byte{2}
	b, err := newRolloverBuffer(native, 100*audio.SampleNS, pairedRolloverCursors(11, 100), now)
	if err != nil {
		t.Fatal(err)
	}
	for seq := uint64(1); seq <= 3; seq++ {
		for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
			f := audio.Frame{SessionID: native, Source: source, Sequence: seq + 10, StartSample: 100 + (seq-1)*2, CaptureOffsetNS: (100 + (seq-1)*2) * audio.SampleNS, Samples: []int16{int16(seq), -int16(seq)}}
			if err := b.append(f, now); err != nil {
				t.Fatal(err)
			}
			f.Samples[0] = 99
		}
	}
	original, mapped, err := b.take(remote, now.Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	for i, f := range mapped {
		seq := uint64(i/2 + 1)
		if f.SessionID != remote || f.Sequence != seq || f.StartSample != (seq-1)*2 || f.CaptureOffsetNS != (seq-1)*2*audio.SampleNS || !reflect.DeepEqual(f.Samples, []int16{int16(seq), -int16(seq)}) {
			t.Fatalf("incorrect mapping: %+v", f)
		}
		if original[i].SessionID != native || original[i].StartSample != 100+(seq-1)*2 {
			t.Fatal("lost provenance")
		}
	}
	if _, _, err = b.take(remote, now); err == nil {
		t.Fatal("replayed buffer")
	}
}
func TestRolloverSplitAtExactSample(t *testing.T) {
	f := audio.Frame{SessionID: [16]byte{1}, Source: audio.CallAudio, Sequence: 4, StartSample: 10, CaptureOffsetNS: 10 * audio.SampleNS, Samples: []int16{1, 2, 3, 4}}
	l, r, err := splitRolloverFrame(f, 12*audio.SampleNS)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(append(append([]int16{}, l.Samples...), r.Samples...), f.Samples) || r.StartSample != 12 || r.Sequence != 4 {
		t.Fatal("cut lost samples/provenance")
	}
	if _, _, err = splitRolloverFrame(f, 12*audio.SampleNS+1); err == nil {
		t.Fatal("unaligned cut accepted")
	}
}
func TestRolloverFailsClosed(t *testing.T) {
	for _, kind := range []string{"cancel", "deadline", "capacity", "gap"} {
		t.Run(kind, func(t *testing.T) {
			now := time.Unix(1, 0)
			b, err := newRolloverBuffer([16]byte{1}, 0, pairedRolloverCursors(1, 0), now)
			if err != nil {
				t.Fatal(err)
			}
			f := audio.Frame{SessionID: [16]byte{1}, Source: audio.Microphone, Sequence: 1, Samples: make([]int16, 1600)}
			f.Samples[0] = 7
			if err := b.append(f, now); err != nil {
				t.Fatal(err)
			}
			retained := b.frames[0].Samples
			switch kind {
			case "cancel":
				b.cancel()
			case "deadline":
				_ = b.append(f, now.Add(rolloverDeadline))
			case "gap":
				f.Sequence = 3
				_ = b.append(f, now)
			case "capacity":
				for i := uint64(1); i <= 80; i++ {
					f.Sequence = i + 1
					f.StartSample = i * 1600
					f.CaptureOffsetNS = i * 1600 * audio.SampleNS
					_ = b.append(f, now)
				}
			}
			if !b.closed || b.frames != nil || retained[0] != 0 {
				t.Fatal("failed buffer retained PCM")
			}
			if _, _, err := b.take([16]byte{2}, now); err == nil {
				t.Fatal("failed buffer replayed")
			}
		})
	}
}

func pairedRolloverCursors(seq, sample uint64) map[audio.Source]rolloverCursor {
	return map[audio.Source]rolloverCursor{audio.Microphone: {seq, sample, sample * audio.SampleNS}, audio.CallAudio: {seq, sample, sample * audio.SampleNS}}
}
func TestRolloverRejectsFirstFrameGap(t *testing.T) {
	now := time.Unix(1, 0)
	b, err := newRolloverBuffer([16]byte{1}, 10*audio.SampleNS, pairedRolloverCursors(4, 10), now)
	if err != nil {
		t.Fatal(err)
	}
	f := audio.Frame{SessionID: [16]byte{1}, Source: audio.Microphone, Sequence: 4, StartSample: 20, CaptureOffsetNS: 20 * audio.SampleNS, Samples: []int16{1}}
	if err = b.append(f, now); err == nil || !b.closed {
		t.Fatal("first-frame gap accepted")
	}
}
