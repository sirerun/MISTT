package service

import (
	"context"
	"encoding/json"
	"fmt"
	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"
	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
	"github.com/sirerun/MISTT/internal/config"
	"github.com/sirerun/MISTT/internal/ipc"
	"testing"
	"time"
)

func rotationReady(id string) backend.Ready {
	return backend.Ready{SessionID: id, Model: "fictional-model", Language: "en", SourceSampleCaps: map[audio.Source]uint64{audio.Microphone: 1920000, audio.CallAudio: 1920000}}
}
func TestBudgetWindowReservesDrainAndUsesBothAdmittedCaps(t *testing.T) {
	r := rotationReady("fictional")
	r.SourceSampleCaps[audio.CallAudio] = 960000
	d, e := budgetCaptureWindow(r, 10*time.Second, 5*time.Second)
	if e != nil || d != 50*time.Second {
		t.Fatal(d, e)
	}
	for _, bad := range []backend.Ready{{}, {SourceSampleCaps: map[audio.Source]uint64{audio.Microphone: 1920000}}, {SourceSampleCaps: map[audio.Source]uint64{audio.Microphone: 16000, audio.CallAudio: 16000}}} {
		if _, e = budgetCaptureWindow(bad, 10*time.Second, 5*time.Second); e == nil {
			t.Fatal("unsafe budget accepted")
		}
	}
	if _, e = budgetCaptureWindow(r, 6*time.Second, 5*time.Second); e == nil {
		t.Fatal("insufficient stop reserve accepted")
	}
}

type rotationFake struct {
	ready   backend.Ready
	events  chan backend.Event
	ended   map[audio.Source]bool
	failure string
	closed  bool
}

func (f *rotationFake) Ready() backend.Ready                        { return f.ready }
func (f *rotationFake) CaptureStarted(backend.CaptureStarted) error { return nil }
func (f *rotationFake) QueueFrame(audio.Frame) error                { return nil }
func (f *rotationFake) Events() <-chan backend.Event                { return f.events }
func (f *rotationFake) Close() error                                { f.closed = true; return nil }
func (f *rotationFake) EndSource(source audio.Source, _ backend.EndRequest) error {
	f.ended[source] = true
	if f.failure == "error" {
		f.events <- backend.Event{SourceDone: &backend.SourceCompletion{Source: source, Success: false, Code: "synthetic_failure"}}
	} else if f.failure != "premature" {
		f.events <- backend.Event{SourceDone: &backend.SourceCompletion{Source: source, Success: true}}
	}
	if len(f.ended) == 2 {
		f.events <- backend.Event{Done: true}
	}
	return nil
}
func newRotationFake(id, failure string) *rotationFake {
	return &rotationFake{ready: rotationReady(id), events: make(chan backend.Event, 8), ended: map[audio.Source]bool{}, failure: failure}
}
func rotationFixture(t *testing.T) (*Service, *activePair, <-chan *misttv1.StreamResponse, func(bool, bool), *json.Decoder) {
	t.Helper()
	cfg := config.Defaults()
	cfg.BudgetRotation = true
	cfg.StartupTimeout = time.Second
	cfg.DrainTimeout = 100 * time.Millisecond
	cfg.RotationHeadroom = 3 * time.Second
	s, reader := serviceWithOutputReader(t, cfg, nil)
	id, e := newUUID()
	if e != nil {
		t.Fatal(e)
	}
	remote := newRotationFake(id, "")
	pair := &activePair{id: id, ready: remote.ready, remote: remote, epochHostNS: 100, sequence: 1, ledgers: map[audio.Source]*sourceLedger{audio.Microphone: {}, audio.CallAudio: {}}, sourceEnds: map[audio.Source]bool{}, budgetDeadline: time.Now()}
	events := make(chan *misttv1.StreamResponse, 16)
	s.active = pair
	s.muted = false
	s.capturing = true
	s.closureConfirmed = false
	s.budgetStarted = time.Now()
	s.clients[1] = &subscriber{id: 1, events: events, done: make(chan struct{}), terminal: make(chan error, 1), language: "en"}
	native := func(late, operatorMute bool) {
		request := readNativeCommand(t, reader)
		if request.Type != "capture_stop" {
			t.Errorf("unexpected native command %s", request.Type)
			return
		}
		if late {
			return
		}
		if operatorMute {
			s.mu.Lock()
			s.muted = true
			s.reason = "user"
			s.mu.Unlock()
		}
		s.incoming <- ipc.Event{Control: &ipc.NativeMessage{Type: "capture_stopped", RequestID: request.RequestID, SessionID: pair.id, CutoffHostNS: 100, MicrophoneIOStopped: true, TapIOStopped: true, TapDestroyed: true, AggregateDestroyed: true}}
		for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
			s.incoming <- ipc.Event{Control: &ipc.NativeMessage{Type: "source_end", SessionID: pair.id, Source: source}}
		}
	}
	return s, pair, events, native, reader
}
func TestRotationKnownStopSettlesBeforeFreshSessionIdentity(t *testing.T) {
	s, pair, events, native, reader := rotationFixture(t)
	go native(false, false)
	s.rotatePair(pair)
	if s.muted || s.active != nil || !s.closureConfirmed || s.budgetRotations != 1 || !s.canStartLocked() {
		t.Fatal("known rotation did not preserve safe demand")
	}
	terminal := <-events
	if terminal.SessionId != pair.id || terminal.GetSessionStopped() == nil || terminal.GetSessionStopped().Reason != budgetRotationReason || terminal.GetSessionStopped().GrpcCode != 0 || terminal.GetSessionStopped().Detail == "" {
		t.Fatal(terminal)
	}
	next := newRotationFake("", "")
	s.backend = providerFunc(func(_ context.Context, r backend.StartRequest) (backend.Session, error) {
		next.ready.SessionID = r.SessionID
		return next, nil
	})
	originalStart := s.budgetStarted
	nativeDone := make(chan error, 1)
	go func() {
		request := readNativeCommand(t, reader)
		if request.Type != "capture_start" {
			nativeDone <- fmt.Errorf("unexpected %s", request.Type)
			return
		}
		s.incoming <- ipc.Event{Control: &ipc.NativeMessage{Type: "capture_started", RequestID: request.RequestID, SessionID: request.SessionID, Sources: request.Sources, MicrophoneReady: true, CallAudioReady: true, CaptureEpochHostNS: 200, CaptureEpochUnixMS: 1000}}
		nativeDone <- nil
	}()
	if e := s.startPair(); e != nil {
		t.Fatal(e)
	}
	if e := <-nativeDone; e != nil {
		t.Fatal(e)
	}
	started := <-events
	if started.GetSessionStarted() == nil || started.SessionId == pair.id || started.Sequence != 1 || s.active == nil || s.active.id != started.SessionId {
		t.Fatal("fresh session not established after known stop", started)
	}
	if s.budgetStarted != originalStart || s.budgetRotations != 1 {
		t.Fatal("rotation reset total operator budget")
	}

}
func TestRotationFailureLateEOFAndGlobalMuteNeverRestart(t *testing.T) {
	for _, mode := range []string{"late", "error", "premature", "mute"} {
		t.Run(mode, func(t *testing.T) {
			s, pair, events, native, _ := rotationFixture(t)
			pair.remote.(*rotationFake).failure = mode
			client := s.clients[1]
			go native(mode == "late", mode == "mute")
			s.rotatePair(pair)
			if !s.muted || s.canStartLocked() || s.budgetRotations != 0 {
				t.Fatal("unsafe rotation eligible for restart")
			}
			if mode == "late" {
				select {
				case <-client.done:
				case <-time.After(time.Second):
					t.Fatal("unknown stop did not terminate stream")
				}
				select {
				case terminal := <-events:
					if terminal.GetSessionStopped() != nil && terminal.GetSessionStopped().GrpcCode == 0 {
						t.Fatal("late EOF falsely settled")
					}
				default:
				}
				return
			}
			select {
			case terminal := <-events:
				if terminal.GetSessionStopped() == nil || terminal.GetSessionStopped().Reason == budgetRotationReason {
					t.Fatal(terminal)
				}
			case <-time.After(time.Second):
				t.Fatal("no explicit terminal")
			}
		})
	}
}
func TestRotationCountAndOverallDurationRemainHardBounds(t *testing.T) {
	for _, overall := range []bool{false, true} {
		t.Run(fmt.Sprint(overall), func(t *testing.T) {
			s, pair, events, native, _ := rotationFixture(t)
			s.cfg.MaxBudgetRotations = 1
			s.budgetRotations = 1
			expected := rotationLimitReason
			if overall {
				s.cfg.MaxDuration = time.Second
				s.budgetStarted = time.Now().Add(-2 * time.Second)
				expected = "max_duration"
			}
			go native(false, false)
			s.rotatePair(pair)
			if !s.muted || s.canStartLocked() {
				t.Fatal("overall/count limit bypassed")
			}
			terminal := <-events
			if terminal.GetSessionStopped() == nil || terminal.GetSessionStopped().Reason != expected {
				t.Fatal(terminal)
			}
		})
	}
}
func TestRotationDefaultDisabledAndMissingCapsFailsBeforeCapture(t *testing.T) {
	cfg := config.Defaults()
	if cfg.BudgetRotation {
		t.Fatal("rotation enabled by default")
	}
	cfg.BudgetRotation = true
	cfg.StartupTimeout = 100 * time.Millisecond
	remote := newRotationFake("", "")
	remote.ready.SourceSampleCaps = nil
	provider := providerFunc(func(_ context.Context, r backend.StartRequest) (backend.Session, error) {
		remote.ready.SessionID = r.SessionID
		return remote, nil
	})
	s, _ := serviceWithOutputReader(t, cfg, provider)
	s.muted = false
	s.clients[1] = &subscriber{language: "en"}
	if e := s.startPair(); e == nil {
		t.Fatal("missing admitted budgets accepted")
	}
	if s.capturing || s.active != nil || !s.closureConfirmed || !remote.closed {
		t.Fatal("invalid admission dispatched native capture")
	}
}

func TestBudgetTimerRequestsSettledRotationProactively(t *testing.T) {
	s, pair, events, native, _ := rotationFixture(t)
	pair.budgetDeadline = time.Now().Add(15 * time.Millisecond)
	go native(false, false)
	started := time.Now()
	s.runPair(pair)
	if time.Since(started) > time.Second || s.budgetRotations != 1 || s.muted {
		t.Fatal("proactive timer did not rotate before the cap")
	}
	if terminal := <-events; terminal.GetSessionStopped() == nil || terminal.GetSessionStopped().Reason != budgetRotationReason {
		t.Fatal(terminal)
	}
}
func TestExpiredOverallBudgetPreventsNewGatewayAdmission(t *testing.T) {
	s, pair, _, _, _ := rotationFixture(t)
	s.active = nil
	s.closureConfirmed = true
	s.capturing = false
	s.cfg.MaxDuration = time.Second
	s.budgetStarted = time.Now().Add(-2 * time.Second)
	called := false
	s.backend = providerFunc(func(context.Context, backend.StartRequest) (backend.Session, error) {
		called = true
		return pair.remote, nil
	})
	if e := s.startPair(); e != nil {
		t.Fatal(e)
	}
	if called || !s.muted || s.reason != "max_duration" {
		t.Fatal("expired total budget admitted another gateway session")
	}
}
