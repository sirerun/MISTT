package service

import (
	"context"
	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
	"github.com/sirerun/MISTT/internal/ipc"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type ownerCountSession struct {
	*handoffSession
	entries     chan int32
	release     chan struct{}
	calls       atomic.Int32
	releaseOnce sync.Once
}

func (o *ownerCountSession) unblock() { o.releaseOnce.Do(func() { close(o.release) }) }
func (o *ownerCountSession) Events() <-chan backend.Event {
	n := o.calls.Add(1)
	select {
	case o.entries <- n:
	default:
	}
	<-o.release // Observe ownership before either owner can consume any frame.
	return o.handoffSession.Events()
}

// The second Events() access is the first rollover select, after the expired
// budget timer has won. Only then feed frames, avoiding select/timer races.
type cutBarrierSession struct {
	*handoffSession
	calls   atomic.Int32
	entered chan struct{}
}

func (o *cutBarrierSession) Events() <-chan backend.Event {
	if o.calls.Add(1) == 2 {
		close(o.entered)
	}
	return o.handoffSession.Events()
}

func TestSupervisorIsOnlySuccessorPairOwner(t *testing.T) {
	s, pair, old, _, decoder := newHandoffHarness(t)
	firstCut := &cutBarrierSession{handoffSession: old, entered: make(chan struct{})}
	pair.remote = firstCut
	var next *ownerCountSession
	connected := make(chan struct{})
	s.backend = providerFunc(func(ctx context.Context, r backend.StartRequest) (backend.Session, error) {
		next = &ownerCountSession{handoffSession: newHandoffSession(r.SessionID), entries: make(chan int32, 4), release: make(chan struct{})}
		close(connected)
		return next, nil
	})
	pair.budgetDeadline = time.Now().Add(-time.Second)
	finished := make(chan struct{})
	go func() { s.supervise(); close(finished) }()
	t.Cleanup(func() {
		s.mu.Lock()
		s.active = nil
		s.mu.Unlock()
		close(s.closed)
		if next != nil {
			next.unblock()
		}
		select {
		case <-finished:
		case <-time.After(time.Second):
			t.Error("supervisor did not stop")
		}
	})
	waitHandoff(t, firstCut.entered)
	for seq := uint64(2); seq <= 3; seq++ {
		for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
			f := handoffFrame(pair.nativeSessionID(), source, seq)
			s.incoming <- ipc.Event{Frame: &f}
		}
	}
	waitHandoff(t, old.ended)
	old.events <- backend.Event{SourceDone: &backend.SourceCompletion{Source: audio.Microphone, Success: true}}
	old.events <- backend.Event{SourceDone: &backend.SourceCompletion{Source: audio.CallAudio, Success: true}}
	old.events <- backend.Event{Done: true}
	waitHandoff(t, connected)
	select {
	case <-next.entries:
	case <-time.After(time.Second):
		t.Fatal("successor never received its supervisor owner")
	}
	select {
	case count := <-next.entries:
		t.Fatalf("successor has %d concurrent runPair owners; incoming frames and timers are shared", count)
	case <-time.After(100 * time.Millisecond):
	}
	// Muting after the handoff still reaches the single owner and settles bounded
	// native closure; closing the supervisor afterwards must not leave an owner.
	s.mu.Lock()
	s.muted = true
	s.reason = "muted"
	active := s.active
	s.signalLocked()
	s.mu.Unlock()
	next.unblock()
	stopHandoffFixture(t, s, active, next.handoffSession, decoder, 3)
	next.events <- backend.Event{Done: true}
	until := time.NewTimer(time.Second)
	defer until.Stop()
	for {
		s.mu.Lock()
		stillActive := s.active != nil
		changed := s.statusChanged
		s.mu.Unlock()
		if !stillActive {
			break
		}
		select {
		case <-changed:
		case <-until.C:
			t.Fatal("mute after rollover did not settle")
		}
	}
}
