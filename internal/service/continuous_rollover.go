package service

import (
	"context"
	"errors"
	"fmt"
	"math"
	"time"

	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"
	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
	"github.com/sirerun/MISTT/internal/ipc"
	"google.golang.org/protobuf/proto"
)

// rolloverPair is the only planned-rotation path that does not stop native IO.
// One goroutine retains exclusive custody of incoming native frames throughout
// cut, old settlement, new admission, and replay. No second ASR pair overlaps.
func (s *Service) rolloverPair(pair *activePair) *activePair {
	started := time.Now()
	deadline := started.Add(rolloverDeadline)
	ctx, cancel := context.WithDeadline(context.Background(), deadline)
	defer cancel()
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	var buffer *rolloverBuffer
	pending := []audio.Frame{}
	var owned []audio.Frame
	retained := map[audio.Source]uint64{}
	cursors := map[audio.Source]rolloverCursor{}
	var successor backend.Session
	cleanup := func() {
		if buffer != nil {
			buffer.cancel()
		}
		for _, f := range pending {
			clear(f.Samples)
		}
		pending = nil
		for _, frame := range owned {
			clear(frame.Samples)
		}
		owned = nil
		if successor != nil {
			_ = successor.Close()
		}
	}
	fail := func(reason string, err error) { cleanup(); s.stopPair(pair, reason, err) }
	interrupted := func() (string, bool) {
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.rotationOverallExpiredLocked(time.Now()) {
			s.muted = true
			s.reason = "max_duration"
		}
		if s.shutdownRequested {
			return "shutdown", true
		}
		if s.muted {
			if s.reason == "max_duration" || s.reason == rotationLimitReason {
				return s.reason, true
			}
			return "muted", true
		}
		if s.updateReserved || len(s.clients) == 0 {
			return "no_clients", true
		}
		return "", false
	}
	// Select a future cut from real captured sample offsets, not a guessed mapping
	// between Go's clock and the native host clock. The extra frame stays inside
	// the existing reserved rotation headroom.
	boundary := uint64(0)
	for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		l := pair.ledgers[source]
		if l == nil || l.frames == 0 {
			fail("backend_failure", errors.New("rollover has no paired native timeline"))
			return nil
		}
		if l.nextSample < l.firstSample || (l.nextSample-l.firstSample) > math.MaxUint64/audio.SampleNS {
			fail("backend_failure", errors.New("rollover source clock overflows"))
			return nil
		}
		delta := (l.nextSample - l.firstSample) * audio.SampleNS
		if l.firstOffset > math.MaxUint64-delta {
			fail("backend_failure", errors.New("rollover source clock overflows"))
			return nil
		}
		end := l.firstOffset + delta
		if end > boundary {
			boundary = end
		}
	}
	if boundary > math.MaxUint64-uint64(100*time.Millisecond) {
		fail("backend_failure", errors.New("rollover cut overflows"))
		return nil
	}
	boundary += uint64(100 * time.Millisecond)
	retain := func(f audio.Frame) error {
		if buffer != nil {
			return buffer.append(f, time.Now())
		}
		count := uint64(len(f.Samples))
		if count > rolloverSamplesPerSource-retained[f.Source] {
			return errors.New("rollover PCM capacity exceeded")
		}
		f.Samples = append([]int16(nil), f.Samples...)
		pending = append(pending, f)
		retained[f.Source] += count
		return nil
	}
	accept := func(event ipc.Event) error {
		if event.Frame == nil {
			return s.activeEvent(pair, event, nil)
		}
		f := *event.Frame
		if err := validateNativeFrame(pair, f, nil); err != nil {
			return err
		}
		if len(cursors) == 2 {
			return retain(f)
		}
		if _, cut := cursors[f.Source]; cut {
			return retain(f)
		}
		left, right, err := splitRolloverFrame(f, boundary)
		if err != nil {
			return err
		}
		if left != nil {
			if err = queueRemoteFrame(pair, *left); err != nil {
				return err
			}
		}
		if right != nil {
			cursors[f.Source] = rolloverCursor{right.Sequence, right.StartSample, right.CaptureOffsetNS}
			if err = retain(*right); err != nil {
				return err
			}
		}
		if len(cursors) == 2 {
			buffer, err = newRolloverBuffer(mustUUID(pair.nativeSessionID()), boundary, cursors, started)
			if err != nil {
				return err
			}
			for _, frame := range pending {
				if err = buffer.append(frame, time.Now()); err != nil {
					return err
				}
				clear(frame.Samples)
			}
			pending = nil
		}
		return nil
	}
	for len(cursors) < 2 {
		if reason, stop := interrupted(); stop {
			fail(reason, nil)
			return nil
		}
		select {
		case <-s.closed:
			fail("native_failure", ErrNativeDisconnected)
			return nil
		case <-s.changed:
			continue
		case <-timer.C:
			fail("backend_failure", errors.New("rollover cut deadline exceeded"))
			return nil
		case event := <-s.incoming:
			if err := accept(event); err != nil {
				fail("native_failure", err)
				return nil
			}
		case e, ok := <-pair.remote.Events():
			if !ok || e.Err != nil || e.Done || e.SourceDone != nil {
				fail("backend_failure", errors.New("old ASR ended before cut"))
				return nil
			}
			if e.Transcript != nil {
				if err := s.publishTranscript(pair, e.Transcript); err != nil {
					fail("backend_failure", err)
					return nil
				}
			}
		}
	}
	// End only the remote streams. Native EOF remains owned by a future real
	// capture_stop acknowledgement and is never fabricated for this handoff.
	pair.syntheticRemoteEnds = true
	pair.remoteCompleted = map[audio.Source]bool{}
	for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		l := pair.transmittedLedger(source)
		if l == nil || boundary < pair.remoteOffsetNS {
			fail("backend_failure", errors.New("missing cut ledger"))
			return nil
		}
		if err := pair.remote.EndSource(source, backend.EndRequest{LastSequence: l.nextSequence, TotalSamples: l.nextSample, CutoffOffsetNS: boundary - pair.remoteOffsetNS}); err != nil {
			fail("backend_failure", err)
			return nil
		}
	}
	for !pair.remoteSettled {
		if reason, stop := interrupted(); stop {
			fail(reason, nil)
			return nil
		}
		select {
		case <-s.closed:
			fail("native_failure", ErrNativeDisconnected)
			return nil
		case <-s.changed:
			continue
		case <-timer.C:
			fail("backend_failure", errors.New("rollover settlement deadline exceeded"))
			return nil
		case event := <-s.incoming:
			if err := accept(event); err != nil {
				fail("native_failure", err)
				return nil
			}
		case e, ok := <-pair.remote.Events():
			if !ok || e.Err != nil {
				fail("backend_failure", errors.New("old ASR closed without settlement"))
				return nil
			}
			if e.Transcript != nil {
				if err := s.publishTranscript(pair, e.Transcript); err != nil {
					fail("backend_failure", err)
					return nil
				}
			}
			if e.SourceDone != nil {
				source := e.SourceDone.Source
				if !source.Valid() || !e.SourceDone.Success || pair.remoteCompleted[source] {
					fail("backend_failure", errors.New("invalid old ASR source settlement"))
					return nil
				}
				pair.remoteCompleted[source] = true
			}
			if e.Done {
				if !pair.remoteCompleted[audio.Microphone] || !pair.remoteCompleted[audio.CallAudio] {
					fail("backend_failure", errors.New("old ASR done before paired settlement"))
					return nil
				}
				pair.remoteSettled = true
			}
		}
	}
	_ = pair.remote.Close() // v2 done proves context cleanup/admission release first.
	id, err := newUUID()
	if err != nil {
		fail("backend_failure", err)
		return nil
	}
	type opened struct {
		session backend.Session
		err     error
	}
	connected := make(chan opened)
	go func() {
		session, err := s.backend.Connect(ctx, backend.StartRequest{SessionID: id, Language: s.cfg.Language, ContinuousCapture: true})
		select {
		case connected <- opened{session, err}:
		case <-ctx.Done():
			if session != nil {
				_ = session.Close()
			}
		}
	}()
	for successor == nil {
		if reason, stop := interrupted(); stop {
			fail(reason, nil)
			return nil
		}
		select {
		case <-s.closed:
			fail("native_failure", ErrNativeDisconnected)
			return nil
		case <-s.changed:
			continue
		case <-timer.C:
			fail("backend_failure", errors.New("rollover admission deadline exceeded"))
			return nil
		case event := <-s.incoming:
			if err := accept(event); err != nil {
				fail("native_failure", err)
				return nil
			}
		case result := <-connected:
			if result.err != nil || result.session == nil {
				if result.session != nil {
					_ = result.session.Close()
				}
				fail("backend_failure", fmt.Errorf("rollover admission failed: %w", result.err))
				return nil
			}
			successor = result.session
		}
	}
	if reason, stop := interrupted(); stop {
		fail(reason, nil)
		return nil
	}
	ready := successor.Ready()
	continuing, ok := successor.(backend.ContinuingSession)
	if !ok || !ready.CaptureContinuation || ready.MaxActivePairs != 1 || ready.Model != pair.ready.Model || ready.Language != pair.ready.Language {
		fail("backend_failure", errors.New("successor ASR contract changed"))
		return nil
	}
	window, err := budgetCaptureWindow(ready, s.cfg.RotationHeadroom, s.cfg.DrainTimeout)
	if err != nil {
		fail("backend_failure", err)
		return nil
	}
	if !started.Add(window).After(time.Now()) {
		fail("backend_failure", errors.New("successor audio budget expired during handoff"))
		return nil
	}
	origins := []backend.CaptureOrigin{}
	for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		c := cursors[source]
		origins = append(origins, backend.CaptureOrigin{Source: source, NativeSequence: c.Sequence, NativeStartSample: c.StartSample, NativeCaptureOffsetNS: c.CaptureOffsetNS})
	}
	if err = continuing.CaptureContinued(backend.CaptureContinuation{NativeSessionID: pair.nativeSessionID(), NativeStarted: pair.nativeStarted, CutoverOffsetNS: boundary, Origins: origins}); err != nil {
		fail("backend_failure", err)
		return nil
	}
	original, _, err := buffer.take(mustUUID(id), time.Now())
	if err != nil {
		fail("backend_failure", err)
		return nil
	}
	owned = original
	next := &activePair{id: id, nativeID: pair.nativeSessionID(), nativeStarted: pair.nativeStarted, remote: successor, ready: ready, epochHostNS: pair.epochHostNS, epochUnixMS: pair.epochUnixMS, sequence: 1, ledgers: pair.ledgers, remoteOffsetNS: boundary, remoteOrigins: cursors, sourceEnds: map[audio.Source]bool{}, seen: map[string]segmentState{}, budgetDeadline: started.Add(window)}
	for i, frame := range original {
		if reason, stop := interrupted(); stop {
			fail(reason, nil)
			return nil
		}
		if err = queueRemoteFrame(next, frame); err != nil {
			for _, tail := range original[i:] {
				clear(tail.Samples)
			}
			fail("backend_failure", err)
			return nil
		}
		clear(frame.Samples)
	}
	attestation, err := settledCaptureContinuation(pair, boundary, cursors)
	if err != nil {
		fail("backend_failure", err)
		return nil
	}
	s.mu.Lock()
	if s.rotationOverallExpiredLocked(time.Now()) {
		s.muted = true
		s.reason = "max_duration"
	}
	if !s.demandLocked() || s.active != pair {
		s.mu.Unlock()
		fail("muted", nil)
		return nil
	}
	pair.sequence++
	stopped := &misttv1.StreamResponse{SessionId: pair.id, Sequence: pair.sequence, Payload: &misttv1.StreamResponse_SessionStopped{SessionStopped: &misttv1.SessionStopped{Reason: budgetRotationReason}}}
	next.started = proto.Clone(pair.started).(*misttv1.StreamResponse)
	next.started.SessionId = id
	next.started.Sequence = 1
	next.started.GetSessionStarted().CaptureContinuation = attestation
	s.active = next
	s.budgetRotations++
	s.reason = "capturing"
	s.broadcastLocked(stopped)
	s.broadcastLocked(next.started)
	s.publishLocked()
	s.mu.Unlock()
	successor = nil // custody transferred to active pair
	return next
}
