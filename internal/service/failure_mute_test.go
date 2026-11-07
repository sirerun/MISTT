package service

import (
	"errors"
	"testing"
	"time"

	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"

	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
	"github.com/sirerun/MISTT/internal/config"
	"github.com/sirerun/MISTT/internal/ipc"
)

type stoppingTestSession struct {
	inertSession
	events chan backend.Event
}

func (s *stoppingTestSession) Events() <-chan backend.Event { return s.events }

func TestFatalPairedStopMutesBeforeClosureAndDoesNotRearm(t *testing.T) {
	for _, tc := range []struct {
		name, reason           string
		cause                  error
		lateFailure, wantMuted bool
	}{
		{name: "native failure", reason: "native_failure", cause: errors.New("synthetic native failure"), wantMuted: true},
		{name: "backend failure", reason: "backend_failure", cause: errors.New("synthetic backend failure"), wantMuted: true},
		{name: "failure during clean stop", reason: "no_clients", lateFailure: true, wantMuted: true},
		{name: "normal stop preserves intent", reason: "no_clients"},
		{name: "normal rotation preserves intent", reason: "budget_rotation"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, reader := serviceWithOutputReader(t, config.Defaults(), nil)
			remote := &stoppingTestSession{events: make(chan backend.Event, 1)}
			pair := &activePair{id: "00112233-4455-6677-8899-aabbccddeeff", remote: remote, sourceEnds: map[audio.Source]bool{audio.Microphone: true, audio.CallAudio: true}}
			s.clients[1] = &subscriber{id: 1, events: make(chan *misttv1.StreamResponse, 8), done: make(chan struct{}), terminal: make(chan error, 1)}
			s.muted = false
			s.capturing = true
			s.closureConfirmed = false
			s.active = pair
			done := make(chan struct{})
			go func() { defer close(done); s.stopPair(pair, tc.reason, tc.cause) }()
			stop := readNativeCommand(t, reader)
			s.mu.Lock()
			initial := s.nativeStatusLocked()
			closed := s.closureConfirmed
			s.mu.Unlock()
			if initial.Muted != (tc.cause != nil) || !initial.Capturing || closed || initial.UpdateReady {
				t.Fatalf("preclosure state=%+v closed=%v", initial, closed)
			}
			if tc.lateFailure {
				s.incoming <- ipc.Event{Control: &ipc.NativeMessage{Type: "capture_failed", SessionID: pair.id, Code: "native_capture_failure", ClosureConfirmed: false}}
			}
			s.incoming <- ipc.Event{Control: &ipc.NativeMessage{Type: "capture_stopped", RequestID: stop.RequestID, SessionID: pair.id, CutoffHostNS: 1, MicrophoneIOStopped: true, TapIOStopped: true, TapDestroyed: true, AggregateDestroyed: true}}
			for {
				m := readNativeMessage(t, reader)
				if m.Type == "status" && !m.Capturing {
					if m.Muted != tc.wantMuted || m.UpdateReady {
						t.Fatalf("closure projection=%+v", m)
					}
					break
				}
			}
			remote.events <- backend.Event{Done: true}
			select {
			case <-done:
			case <-time.After(time.Second):
				t.Fatal("stop did not finish")
			}
			s.mu.Lock()
			final := s.nativeStatusLocked()
			active := s.active
			canStart := s.canStartLocked()
			s.mu.Unlock()
			if tc.wantMuted && canStart {
				t.Fatal("fatal stop rearmed despite retained client demand")
			}
			if final.Muted != tc.wantMuted || final.Capturing || active != nil {
				t.Fatalf("final state=%+v active=%v", final, active != nil)
			}
		})
	}
}
