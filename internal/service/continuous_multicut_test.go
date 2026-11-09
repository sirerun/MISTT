package service

import (
	"fmt"
	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
	"github.com/sirerun/MISTT/internal/ipc"
	"testing"
	"time"
)

// Exercise actual coordinator/PCM mapping through110/220/330 seconds without
// wall-clock sleeps. Native ledgers remain global; each remote ledger resets.
func TestContinuousSecondAndThirdCutsKeepNativeGlobalCoordinates(t *testing.T) {
	s, pair, remote, _, _ := newHandoffHarness(t)
	native := pair.nativeSessionID()
	type sentGeneration struct {
		session *handoffSession
		origin  uint64
	}
	sent := []sentGeneration{}
	for generation := uint64(1); generation <= 3; generation++ {
		firstAtCut := generation*110*10 + 1 //100ms callbacks, right tail starts exactly at cut.
		for seq := pair.ledgers[audio.CallAudio].nextSequence + 1; seq < firstAtCut-1; seq++ {
			for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
				if err := s.acceptFrame(pair, handoffFrame(native, source, seq), nil); err != nil {
					t.Fatal(err)
				}
			}
		}
		provider := &handoffProvider{old: remote, called: make(chan struct{}), allow: make(chan struct{})}
		s.backend = provider
		result := make(chan *activePair, 1)
		go func(old *activePair) { result <- s.rolloverPair(old) }(pair)
		for seq := firstAtCut - 1; seq <= firstAtCut; seq++ {
			for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
				f := handoffFrame(native, source, seq)
				s.incoming <- ipc.Event{Frame: &f}
			}
		}
		waitHandoff(t, remote.ended)
		remote.events <- backend.Event{SourceDone: &backend.SourceCompletion{Source: audio.Microphone, Success: true}}
		remote.events <- backend.Event{SourceDone: &backend.SourceCompletion{Source: audio.CallAudio, Success: true}}
		remote.events <- backend.Event{Done: true}
		waitHandoff(t, provider.called)
		close(provider.allow)
		var next *activePair
		select {
		case next = <-result:
		case <-time.After(time.Second):
			t.Fatal("offline handoff timed out")
		}
		if next == nil {
			t.Fatalf("cut%d failed", generation)
		}
		expected := generation * uint64(110*time.Second)
		if next.remoteOffsetNS != expected {
			t.Fatalf("cut%d: native-global cut=%d want%d", generation, next.remoteOffsetNS, expected)
		}
		proof := next.started.GetSessionStarted().GetCaptureContinuation()
		if proof == nil || proof.CutoverOffsetNs != expected || proof.PreviousSessionId != pair.id || proof.NativeSessionId != native {
			t.Fatalf("cut%d lost proof", generation)
		}
		for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
			end := remote.ends[source]
			if end.TotalSamples != 110*16000 || end.CutoffOffsetNS != uint64(110*time.Second) {
				t.Fatalf("cut%d %s remote-local end=%+v", generation, source, end)
			}
			if next.remoteOrigins[source].StartSample != generation*110*16000 || next.ledgers[source].nextSample != firstAtCut*1600 {
				t.Fatalf("cut%d %s origins/global ledger lost", generation, source)
			}
		}
		sent = append(sent, sentGeneration{remote, pair.remoteOffsetNS})
		pair, remote = next, provider.next
	}
	sent = append(sent, sentGeneration{remote, pair.remoteOffsetNS})
	seen := map[string]bool{}
	for _, g := range sent {
		for _, f := range g.session.frames {
			nativeSample := f.StartSample + g.origin/audio.SampleNS
			key := fmt.Sprintf("%s:%d", f.Source, nativeSample)
			if seen[key] {
				t.Fatal("duplicate native PCM", key)
			}
			seen[key] = true
			if len(f.Samples) != 1600 || f.Samples[0] != int16(nativeSample/1600+1) {
				t.Fatal("PCM changed", key)
			}
		}
	}
	if len(seen) != 2*3301 {
		t.Fatalf("lost native frames: got%d want%d", len(seen), 2*3301)
	}
}
