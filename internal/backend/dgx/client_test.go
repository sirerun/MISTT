package dgx

import (
	"testing"

	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
)

func readyFixture() readyWire {
	return readyWire{Type: "ready", Protocol: protocol, SessionID: "00112233-4455-6677-8899-aabbccddeeff", Language: "en", Model: "fixture-model", MaxActivePairs: 1, MaxInferenceWorkers: 1, StartupTimeoutMS: 180000, DrainTimeoutMS: 5000, AggregateMaxAudioSamples: 32000, AggregateMaxQueueFrames: 8, AggregateMaxContextTokens: 2000, AggregateDrainReserveModelSamples: 100, AggregateDrainReserveTokens: 20, Sources: []sourceLimit{
		{Source: audio.Microphone, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding, MaxFrameSamples: 1600, MaxQueueFrames: 4, MaxAudioSamples: 16000, MaxContextTokens: 1000, DrainReserveModelSamples: 50, DrainReserveTokens: 10},
		{Source: audio.CallAudio, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding, MaxFrameSamples: 1600, MaxQueueFrames: 4, MaxAudioSamples: 16000, MaxContextTokens: 1000, DrainReserveModelSamples: 50, DrainReserveTokens: 10},
	}}
}

func TestReadyRequiresPairedBoundedResources(t *testing.T) {
	r := readyFixture()
	req := backend.StartRequest{SessionID: r.SessionID, Language: r.Language}
	want := []backend.SourceFormat{{Source: audio.Microphone, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}, {Source: audio.CallAudio, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}}
	if err := validateReady(r, req, want); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func(*readyWire){
		"one source":            func(v *readyWire) { v.Sources = v.Sources[:1] },
		"wrong order":           func(v *readyWire) { v.Sources[0], v.Sources[1] = v.Sources[1], v.Sources[0] },
		"multiple pairs":        func(v *readyWire) { v.MaxActivePairs = 2 },
		"multiple workers":      func(v *readyWire) { v.MaxInferenceWorkers = 2 },
		"oversized frame":       func(v *readyWire) { v.Sources[0].MaxFrameSamples = 1601 },
		"missing drain reserve": func(v *readyWire) { v.AggregateDrainReserveTokens = 19 },
		"excess queue":          func(v *readyWire) { v.AggregateMaxQueueFrames = 7 },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			v := readyFixture()
			mutate(&v)
			if err := validateReady(v, req, want); err == nil {
				t.Fatal("accepted unsafe ready")
			}
		})
	}
}

func TestPerSourceQueueIsBoundedAndEOFSealsSource(t *testing.T) {
	ready := readyFixture()
	limits := map[audio.Source]sourceLimit{audio.Microphone: ready.Sources[0], audio.CallAudio: ready.Sources[1]}
	s := &ClientSession{ready: backend.Ready{SessionID: ready.SessionID}, mic: make(chan audio.Frame, 1), call: make(chan audio.Frame, 1), ended: map[audio.Source]bool{}, ends: map[audio.Source]backend.EndRequest{}, limits: limits, queued: map[audio.Source]backend.EndRequest{}, closed: make(chan struct{})}
	id, _ := audio.ParseUUID(ready.SessionID)
	frame := audio.Frame{SessionID: id, Source: audio.Microphone, Sequence: 1, Samples: []int16{1, 2}}
	if err := s.QueueFrame(frame); err != nil {
		t.Fatal(err)
	}
	frame.Sequence = 2
	frame.StartSample = 2
	if err := s.QueueFrame(frame); err != ErrQueueFull {
		t.Fatalf("want bounded queue full, got %v", err)
	}
	if err := s.EndSource(audio.Microphone, backend.EndRequest{LastSequence: 1, TotalSamples: 2, CutoffOffsetNS: 1}); err != nil {
		t.Fatal(err)
	}
	if err := s.QueueFrame(frame); err == nil {
		t.Fatal("accepted frame after source EOF")
	}
	if err := s.EndSource(audio.CallAudio, backend.EndRequest{CutoffOffsetNS: 2}); err == nil {
		t.Fatal("accepted mismatched paired cutoff")
	}
}
