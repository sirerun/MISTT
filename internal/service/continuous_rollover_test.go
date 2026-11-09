package service

import (
	"context"
	"encoding/json"
	"sync"
	"testing"
	"time"

	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"
	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
	"github.com/sirerun/MISTT/internal/config"
	"github.com/sirerun/MISTT/internal/ipc"
)

type handoffSession struct {
	mu           sync.Mutex
	ready        backend.Ready
	events       chan backend.Event
	frames       []audio.Frame
	ends         map[audio.Source]backend.EndRequest
	ended        chan struct{}
	continuation *backend.CaptureContinuation
}

func newHandoffSession(id string) *handoffSession {
	r := rotationReady(id)
	r.MaxActivePairs = 1
	r.CaptureContinuation = true
	return &handoffSession{ready: r, events: make(chan backend.Event, 8), ends: map[audio.Source]backend.EndRequest{}, ended: make(chan struct{})}
}
func (h *handoffSession) Ready() backend.Ready                        { return h.ready }
func (h *handoffSession) CaptureStarted(backend.CaptureStarted) error { return nil }
func (h *handoffSession) CaptureContinued(c backend.CaptureContinuation) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.continuation = &c
	return nil
}
func (h *handoffSession) QueueFrame(f audio.Frame) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	f.Samples = append([]int16(nil), f.Samples...)
	h.frames = append(h.frames, f)
	return nil
}
func (h *handoffSession) EndSource(source audio.Source, end backend.EndRequest) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.ends[source] = end
	if len(h.ends) == 2 {
		close(h.ended)
	}
	return nil
}
func (h *handoffSession) Events() <-chan backend.Event { return h.events }
func (h *handoffSession) Close() error                 { return nil }
func (h *handoffSession) count() int                   { h.mu.Lock(); defer h.mu.Unlock(); return len(h.frames) }

type handoffProvider struct {
	old    *handoffSession
	called chan struct{}
	allow  chan struct{}
	mu     sync.Mutex
	next   *handoffSession
}

func (h *handoffProvider) Connect(ctx context.Context, r backend.StartRequest) (backend.Session, error) {
	select {
	case <-h.old.ended:
	default:
		panic("successor opened before old streams ended")
	}
	close(h.called)
	select {
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-h.allow:
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	h.next = newHandoffSession(r.SessionID)
	return h.next, nil
}
func handoffFrame(id string, source audio.Source, seq uint64) audio.Frame {
	samples := make([]int16, 1600)
	for i := range samples {
		samples[i] = int16(seq)
	}
	return audio.Frame{SessionID: mustUUID(id), Source: source, Sequence: seq, StartSample: (seq - 1) * 1600, CaptureOffsetNS: (seq - 1) * 1600 * audio.SampleNS, Samples: samples}
}
func waitHandoff(t *testing.T, ch <-chan struct{}) {
	t.Helper()
	select {
	case <-ch:
	case <-time.After(time.Second):
		t.Fatal("handoff phase timed out")
	}
}

func TestContinuousRolloverQueuesSpeechUntilOldSettlementAndNewReadiness(t *testing.T) {
	s, pair, old, provider, _ := newHandoffHarness(t)
	id := pair.id
	result := make(chan *activePair, 1)
	go func() { result <- s.rolloverPair(pair) }()
	for seq := uint64(2); seq <= 3; seq++ {
		for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
			f := handoffFrame(id, source, seq)
			s.incoming <- ipc.Event{Frame: &f}
		}
	}
	waitHandoff(t, old.ended)
	select {
	case <-provider.called:
		t.Fatal("new admission before old settlement")
	default:
	}
	for seq := uint64(4); seq <= 5; seq++ {
		for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
			f := handoffFrame(id, source, seq)
			s.incoming <- ipc.Event{Frame: &f}
		}
	}
	old.events <- backend.Event{SourceDone: &backend.SourceCompletion{Source: audio.Microphone, Success: true}}
	old.events <- backend.Event{SourceDone: &backend.SourceCompletion{Source: audio.CallAudio, Success: true}}
	old.events <- backend.Event{Done: true}
	waitHandoff(t, provider.called)
	for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		f := handoffFrame(id, source, 6)
		s.incoming <- ipc.Event{Frame: &f}
	}
	// FIFO frames are queued before admission; give a same-channel native marker
	// an observation barrier by admitting only once all native ledgers reach6.
	until := time.Now().Add(time.Second)
	for len(s.incoming) > 0 && time.Now().Before(until) {
		time.Sleep(time.Millisecond)
	}
	close(provider.allow)
	var next *activePair
	select {
	case next = <-result:
	case <-time.After(time.Second):
		t.Fatal("handoff did not finish")
	}
	if next == nil {
		t.Fatal("handoff failed")
	}
	if next.nativeSessionID() != id || next.id == id || !pair.remoteSettled || !pair.syntheticRemoteEnds || next.remoteOffsetNS != 200_000_000 {
		t.Fatal("generation/cut proof lost")
	}
	proof := next.started.GetSessionStarted().GetCaptureContinuation()
	if proof == nil || proof.Version != 1 || proof.PreviousSessionId != id || proof.NativeSessionId != id || len(proof.Sources) != 2 || proof.Sources[1].StartSample != 3200 {
		t.Fatal("missing settled capture attestation")
	}
	if old.count() != 4 || provider.next.count() != 8 {
		t.Fatalf("sample stream lost/duplicated: oldframes=%d newframes=%d", old.count(), provider.next.count())
	}
	provider.next.mu.Lock()
	defer provider.next.mu.Unlock()
	c := provider.next.continuation
	if c == nil || c.NativeSessionID != id || c.NativeStarted.CaptureEpochHostNS != 1 || c.CutoverOffsetNS != 200_000_000 {
		t.Fatal("native restart was fabricated")
	}
	for _, f := range provider.next.frames {
		if f.SessionID != mustUUID(next.id) || f.Sequence < 1 || f.Sequence > 4 || f.StartSample != (f.Sequence-1)*1600 || f.Samples[0] != int16(f.Sequence+2) {
			t.Fatal("queued speech provenance/PCM changed")
		}
	}
}
func newHandoffHarness(t *testing.T) (*Service, *activePair, *handoffSession, *handoffProvider, *json.Decoder) {
	id := "00112233-4455-6677-8899-aabbccddeeff"
	old := newHandoffSession(id)
	provider := &handoffProvider{old: old, called: make(chan struct{}), allow: make(chan struct{})}
	cfg := config.Defaults()
	cfg.BudgetRotation = true
	cfg.ContinuousRollover = true
	s, decoder := serviceWithOutputReader(t, cfg, provider)
	pair := &activePair{id: id, nativeID: id, nativeStarted: backend.CaptureStarted{RequestID: id, CaptureEpochHostNS: 1, CaptureEpochUnixMS: 1, MicrophoneReady: true, CallAudioReady: true, Sources: []backend.SourceFormat{{Source: audio.Microphone, SampleRateHz: 16000, Channels: 1, Encoding: "s16le"}, {Source: audio.CallAudio, SampleRateHz: 16000, Channels: 1, Encoding: "s16le"}}}, remote: old, ready: old.ready, epochHostNS: 1, epochUnixMS: 1, sequence: 1, ledgers: map[audio.Source]*sourceLedger{audio.Microphone: {}, audio.CallAudio: {}}, sourceEnds: map[audio.Source]bool{}, seen: map[string]segmentState{}, started: &misttv1.StreamResponse{SessionId: id, Sequence: 1, Payload: &misttv1.StreamResponse_SessionStarted{SessionStarted: &misttv1.SessionStarted{Backend: "dgx_paired", Model: old.ready.Model, Language: "en", SampleRateHz: 16000, Channels: 1, Encoding: "s16le", CaptureEpochHostNs: 1, CaptureEpochUnixMs: 1, Sources: []*misttv1.SourceFormat{{Source: "microphone", SampleRateHz: 16000, Channels: 1, Encoding: "s16le"}, {Source: "call_audio", SampleRateHz: 16000, Channels: 1, Encoding: "s16le"}}}}}}
	for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		if err := s.acceptFrame(pair, handoffFrame(id, source, 1), nil); err != nil {
			t.Fatal(err)
		}
	}
	s.mu.Lock()
	s.active = pair
	s.muted = false
	s.capturing = true
	s.closureConfirmed = false
	s.clients[1] = &subscriber{id: 1, events: make(chan *misttv1.StreamResponse, 16), done: make(chan struct{})}
	s.mu.Unlock()

	return s, pair, old, provider, decoder
}

func stopHandoffFixture(t *testing.T, s *Service, pair *activePair, old *handoffSession, decoder *json.Decoder, last uint64) {
	t.Helper()
	for {
		message := readNativeMessage(t, decoder)
		if message.Type != "capture_stop" {
			continue
		}
		if message.SessionID != pair.nativeSessionID() {
			t.Fatal("stop targeted ASR generation instead of native capture")
		}
		s.incoming <- ipc.Event{Control: &ipc.NativeMessage{Type: "capture_stopped", RequestID: message.RequestID, SessionID: pair.nativeSessionID(), CutoffHostNS: 9_000_000_001, MicrophoneIOStopped: true, TapIOStopped: true, TapDestroyed: true, AggregateDestroyed: true, ClosureConfirmed: true}}
		break
	}
	for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		s.incoming <- ipc.Event{Control: &ipc.NativeMessage{Type: "source_end", SessionID: pair.nativeSessionID(), Source: source, LastSequence: last, TotalSamples: last * 1600}}
	}
	old.events <- backend.Event{SourceDone: &backend.SourceCompletion{Source: audio.Microphone, Success: true}}
	old.events <- backend.Event{SourceDone: &backend.SourceCompletion{Source: audio.CallAudio, Success: true}}
	old.events <- backend.Event{Done: true}
}
func TestContinuousRolloverMuteClearsHandoffAndStopsOriginalNativeCapture(t *testing.T) {
	s, pair, old, provider, decoder := newHandoffHarness(t)
	result := make(chan *activePair, 1)
	go func() { result <- s.rolloverPair(pair) }()
	for seq := uint64(2); seq <= 3; seq++ {
		for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
			f := handoffFrame(pair.id, source, seq)
			s.incoming <- ipc.Event{Frame: &f}
		}
	}
	waitHandoff(t, old.ended)
	s.mu.Lock()
	s.muted = true
	s.reason = "muted"
	s.signalLocked()
	s.mu.Unlock()
	stopHandoffFixture(t, s, pair, old, decoder, 3)
	select {
	case next := <-result:
		if next != nil {
			t.Fatal("mute rearmed capture")
		}
	case <-time.After(time.Second):
		t.Fatal("mute handoff did not finish")
	}
	select {
	case <-provider.called:
		t.Fatal("mute admitted successor")
	default:
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.muted || s.active != nil || !s.closureConfirmed {
		t.Fatal("mute lost stop proof")
	}
}
func TestContinuousRolloverCapacityFailsClosedWithoutSuccessor(t *testing.T) {
	s, pair, old, provider, decoder := newHandoffHarness(t)
	result := make(chan *activePair, 1)
	go func() { result <- s.rolloverPair(pair) }()
	for seq := uint64(2); seq <= 83; seq++ {
		for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
			f := handoffFrame(pair.id, source, seq)
			s.incoming <- ipc.Event{Frame: &f}
		}
	}
	waitHandoff(t, old.ended)
	stopHandoffFixture(t, s, pair, old, decoder, 83)
	select {
	case next := <-result:
		if next != nil {
			t.Fatal("overflow admitted successor")
		}
	case <-time.After(time.Second):
		t.Fatal("overflow did not stop")
	}
	select {
	case <-provider.called:
		t.Fatal("overflow opened successor")
	default:
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.muted || s.active != nil || !s.closureConfirmed {
		t.Fatal("overflow did not fail closed")
	}
}

func TestContinuousRolloverDeadlineFailsClosed(t *testing.T) {
	s, pair, old, provider, decoder := newHandoffHarness(t)
	result := make(chan *activePair, 1)
	go func() { result <- s.rolloverPair(pair) }()
	for seq := uint64(2); seq <= 3; seq++ {
		for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
			f := handoffFrame(pair.id, source, seq)
			s.incoming <- ipc.Event{Frame: &f}
		}
	}
	waitHandoff(t, old.ended)
	// Leave old admission unsettled. The production ten-second deadline must
	// stop the real native generation rather than retry or open another pair.
	stopHandoffFixture(t, s, pair, old, decoder, 3)
	select {
	case next := <-result:
		if next != nil {
			t.Fatal("deadline admitted successor")
		}
	case <-time.After(time.Second):
		t.Fatal("deadline did not stop")
	}
	select {
	case <-provider.called:
		t.Fatal("deadline opened successor")
	default:
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.muted || s.active != nil || !s.closureConfirmed {
		t.Fatal("deadline lost native closure proof")
	}
}
