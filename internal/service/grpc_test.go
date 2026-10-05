package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"testing"
	"time"

	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"
	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
	"github.com/sirerun/MISTT/internal/config"
	"github.com/sirerun/MISTT/internal/ipc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

type providerFunc func(context.Context, backend.StartRequest) (backend.Session, error)

func (f providerFunc) Connect(ctx context.Context, req backend.StartRequest) (backend.Session, error) {
	return f(ctx, req)
}

type inertSession struct{ ready backend.Ready }

func (s *inertSession) Ready() backend.Ready                           { return s.ready }
func (*inertSession) CaptureStarted(backend.CaptureStarted) error      { return nil }
func (*inertSession) QueueFrame(audio.Frame) error                     { return nil }
func (*inertSession) EndSource(audio.Source, backend.EndRequest) error { return nil }
func (*inertSession) Events() <-chan backend.Event                     { return make(chan backend.Event) }
func (*inertSession) Close() error                                     { return nil }

func serviceWithOutputReader(t *testing.T, cfg config.Config, provider backend.Provider) (*Service, *json.Decoder) {
	t.Helper()
	readEnd, writeEnd, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	output := ipc.NewWriter(writeEnd, 8)
	t.Cleanup(func() { output.Close(); _ = writeEnd.Close(); _ = readEnd.Close() })
	return New(cfg, provider, nil, output), json.NewDecoder(readEnd)
}

func readNativeMessage(t *testing.T, reader *json.Decoder) ipc.NativeMessage {
	t.Helper()
	var message ipc.NativeMessage
	if err := reader.Decode(&message); err != nil {
		t.Fatalf("read native message: %v", err)
	}
	return message
}

func readNativeCommand(t *testing.T, reader *json.Decoder) ipc.NativeMessage {
	t.Helper()
	for {
		message := readNativeMessage(t, reader)
		if message.Type != "status" {
			return message
		}
	}
}

func newTestService(t *testing.T, cfg config.Config, withNativeInput bool) *Service {
	t.Helper()
	readEnd, writeEnd, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	output := ipc.NewWriter(writeEnd, 8)
	var input io.Reader
	if withNativeInput {
		input = readEnd
	}
	t.Cleanup(func() {
		output.Close()
		_ = writeEnd.Close()
		_ = readEnd.Close()
	})
	return New(cfg, nil, input, output)
}

func TestRealGRPCStatusAndRevisionGuard(t *testing.T) {
	s := newTestService(t, config.Config{}, false)
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	misttv1.RegisterMisttServer(server, s)
	go server.Serve(lis)
	defer server.Stop()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	conn, err := grpc.NewClient(lis.Addr().String(), grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	client := misttv1.NewMisttClient(conn)
	stream, err := client.WatchStatus(ctx, &misttv1.WatchStatusRequest{})
	if err != nil {
		t.Fatal(err)
	}
	initial, err := stream.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if !initial.Muted || !initial.UpdateReady || initial.Revision != 1 {
		t.Fatalf("unexpected initial status: %+v", initial)
	}
	requestID := "00112233-4455-6677-8899-aabbccddeeff"
	updated, err := client.SetMuted(ctx, &misttv1.SetMutedRequest{Muted: false, ExpectedRevision: initial.Revision, RequestId: requestID})
	if err != nil {
		t.Fatal(err)
	}
	if updated.Muted || updated.Revision <= initial.Revision {
		t.Fatalf("mute transition not published: %+v", updated)
	}
	replayed, err := client.SetMuted(ctx, &misttv1.SetMutedRequest{Muted: false, ExpectedRevision: initial.Revision, RequestId: requestID})
	if err != nil || replayed.Revision != updated.Revision || replayed.Muted {
		t.Fatalf("request retry was not idempotent: status=%+v err=%v", replayed, err)
	}
	_, err = client.SetMuted(ctx, &misttv1.SetMutedRequest{Muted: true, ExpectedRevision: initial.Revision, RequestId: "10112233-4455-6677-8899-aabbccddeeff"})
	if status.Code(err) != codes.Aborted {
		t.Fatalf("stale revision should abort, got %v", err)
	}
}

func TestRunClosesWriterWhenListenerIsMissing(t *testing.T) {
	s := newTestService(t, config.Defaults(), false)
	if err := s.Run(context.Background(), nil); err == nil {
		t.Fatal("Run accepted a nil listener")
	}
	if err := s.output.SendControl(ipc.NativeMessage{Type: "heartbeat"}); err != ipc.ErrWriterClosed {
		t.Fatalf("writer after Run failure = %v, want %v", err, ipc.ErrWriterClosed)
	}
}

func TestMuteRequestCacheEvictsCompletedEntriesBeforeInsert(t *testing.T) {
	s := newTestService(t, config.Defaults(), false)
	for i := 1; i <= 130; i++ {
		id := fmt.Sprintf("%08x-0000-4000-8000-%012x", i, i)
		if _, err := s.SetMuted(context.Background(), &misttv1.SetMutedRequest{RequestId: id, Muted: true, ExpectedRevision: 1}); err != nil {
			t.Fatalf("completed request %d was rejected: %v", i, err)
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.muteRequests) != 128 {
		t.Fatalf("completed request cache exceeded or underfilled bound: %d", len(s.muteRequests))
	}
	if _, ok := s.muteRequests[fmt.Sprintf("%08x-0000-4000-8000-%012x", 1, 1)]; ok {
		t.Fatal("oldest completed idempotency record was not evicted")
	}
	if _, ok := s.muteRequests[fmt.Sprintf("%08x-0000-4000-8000-%012x", 130, 130)]; !ok {
		t.Fatal("newest completed idempotency record was lost")
	}
}

func TestMuteRequestCacheRejectsWhenAllEntriesArePending(t *testing.T) {
	s := newTestService(t, config.Defaults(), false)
	for i := 1; i <= 128; i++ {
		id := fmt.Sprintf("%08x-0000-4000-8000-%012x", i, i)
		s.muteRequests[id] = &muteRecord{payload: "pending", done: make(chan struct{})}
		s.muteOrder = append(s.muteOrder, id)
	}
	_, err := s.SetMuted(context.Background(), &misttv1.SetMutedRequest{RequestId: "00000081-0000-4000-8000-000000000081", Muted: true, ExpectedRevision: 1})
	if status.Code(err) != codes.ResourceExhausted {
		t.Fatalf("full pending cache should reject without evicting in-flight requests, got %v", err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.muteRequests) != 128 {
		t.Fatalf("pending request cache exceeded bound: %d", len(s.muteRequests))
	}
}

func TestNativeUpdateReservationAndCommandReplay(t *testing.T) {
	s := newTestService(t, config.Config{}, false)
	prepare := ipc.NativeMessage{Type: "native_prepare_update", RequestID: "00112233-4455-6677-8899-aabbccddeeff", CommandSequence: 1, ExpectedStatusRevision: 1}
	if err := s.applyNativeCommand(prepare); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	reserved, revision := s.updateReserved, s.revision
	s.mu.Unlock()
	if !reserved || revision != 2 {
		t.Fatalf("prepare did not reserve idle state: reserved=%t revision=%d", reserved, revision)
	}
	if err := s.applyNativeCommand(prepare); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	revisionAfterReplay := s.revision
	s.mu.Unlock()
	if revisionAfterReplay != revision {
		t.Fatal("idempotent replay changed state")
	}
	unmute := ipc.NativeMessage{Type: "native_set_muted", RequestID: "10112233-4455-6677-8899-aabbccddeeff", CommandSequence: 2, ExpectedStatusRevision: revision, Muted: false}
	if err := s.applyNativeCommand(unmute); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	muted := s.muted
	revision = s.revision
	s.mu.Unlock()
	if !muted {
		t.Fatal("update reservation allowed unmute")
	}
	cancel := ipc.NativeMessage{Type: "native_cancel_update", RequestID: "20112233-4455-6677-8899-aabbccddeeff", CommandSequence: 3, ExpectedStatusRevision: revision}
	if err := s.applyNativeCommand(cancel); err != nil {
		t.Fatal(err)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.updateReserved || !s.muted || !s.updateReadyLocked() {
		t.Fatal("cancel did not release reservation while preserving muted safe-idle state")
	}
}

func TestNativeMuteResultWaitsForPairedClosure(t *testing.T) {
	s := newTestService(t, config.Defaults(), false)
	s.muted, s.capturing, s.closureConfirmed = false, true, false
	s.active = &activePair{ready: backend.Ready{DrainTimeoutMS: 5000}}
	command := ipc.NativeMessage{Type: "native_set_muted", RequestID: "00112233-4455-6677-8899-aabbccddeeff", CommandSequence: 1, ExpectedStatusRevision: 1, Muted: true}
	done := make(chan error, 1)
	go func() { done <- s.applyNativeCommandAt(command, time.Now()) }()
	select {
	case err := <-done:
		t.Fatalf("mute result returned before closure: %v", err)
	case <-time.After(30 * time.Millisecond):
	}
	s.mu.Lock()
	s.active, s.capturing, s.stopping, s.closureConfirmed = nil, false, false, true
	s.publishLocked()
	s.mu.Unlock()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("mute result did not follow confirmed closure")
	}
}

func TestMuteDuringRemoteStartupCancelsBeforeNativeDispatch(t *testing.T) {
	connected := make(chan struct{})
	provider := providerFunc(func(ctx context.Context, _ backend.StartRequest) (backend.Session, error) {
		close(connected)
		<-ctx.Done()
		return nil, ctx.Err()
	})
	s, reader := serviceWithOutputReader(t, config.Defaults(), provider)
	s.mu.Lock()
	s.muted = false
	s.clients[1] = &subscriber{id: 1}
	s.mu.Unlock()
	startDone := make(chan error, 1)
	go func() { startDone <- s.startPair() }()
	select {
	case <-connected:
	case <-time.After(time.Second):
		t.Fatal("start did not reach remote readiness")
	}
	s.mu.Lock()
	if !s.starting || s.startCancel == nil {
		s.mu.Unlock()
		t.Fatal("starting state was visible without an installed cancel function")
	}
	revision := s.revision
	s.mu.Unlock()
	muteDone := make(chan error, 1)
	go func() {
		_, err := s.setMuted(context.Background(), &misttv1.SetMutedRequest{Muted: true, ExpectedRevision: revision})
		muteDone <- err
	}()
	select {
	case err := <-startDone:
		if err != nil {
			t.Fatalf("canceled pre-dispatch start returned error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("start did not unwind after mute cancellation")
	}
	select {
	case err := <-muteDone:
		if err != nil {
			t.Fatalf("mute failed while canceling pre-dispatch start: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("mute waited forever for a native start that was never dispatched")
	}
	// No native command should have been emitted. The decoder times out by
	// closing its pipe during test cleanup if this invariant is violated.
	message := make(chan error, 1)
	go func() {
		for {
			var m ipc.NativeMessage
			if err := reader.Decode(&m); err != nil {
				message <- err
				return
			}
			if m.Type != "status" {
				message <- fmt.Errorf("unexpected native command %q", m.Type)
				return
			}
		}
	}()
	select {
	case err := <-message:
		t.Fatalf("pre-dispatch cancellation wrote a native command (decode err %v)", err)
	case <-time.After(30 * time.Millisecond):
	}
}

func TestMuteAfterNativeStartDispatchWaitsForStopAckAndBlocksUnmute(t *testing.T) {
	provider := providerFunc(func(_ context.Context, req backend.StartRequest) (backend.Session, error) {
		return &inertSession{ready: backend.Ready{SessionID: req.SessionID, Model: "test", Language: req.Language, DrainTimeoutMS: 1000}}, nil
	})
	s, reader := serviceWithOutputReader(t, config.Defaults(), provider)
	s.mu.Lock()
	s.muted = false
	s.clients[1] = &subscriber{id: 1}
	s.mu.Unlock()
	startDone := make(chan error, 1)
	go func() { startDone <- s.startPair() }()
	start := readNativeCommand(t, reader)
	if start.Type != "capture_start" {
		t.Fatalf("first native command is %q, want capture_start", start.Type)
	}
	s.mu.Lock()
	if s.closureConfirmed {
		s.mu.Unlock()
		t.Fatal("native start dispatch left closure optimistically confirmed")
	}
	revision := s.revision
	s.mu.Unlock()
	muteDone := make(chan error, 1)
	go func() {
		_, err := s.setMuted(context.Background(), &misttv1.SetMutedRequest{Muted: true, ExpectedRevision: revision})
		muteDone <- err
	}()
	stop := readNativeCommand(t, reader)
	if stop.Type != "capture_stop" || stop.SessionID != start.SessionID {
		t.Fatalf("canceled startup stop = %+v, want capture_stop for session %s", stop, start.SessionID)
	}
	select {
	case err := <-muteDone:
		t.Fatalf("mute acknowledged before native closure ACK: %v", err)
	case <-time.After(30 * time.Millisecond):
	}
	s.mu.Lock()
	unmuteRevision := s.revision
	s.mu.Unlock()
	_, err := s.setMuted(context.Background(), &misttv1.SetMutedRequest{Muted: false, ExpectedRevision: unmuteRevision})
	if status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("unmute before closure ACK = %v, want FailedPrecondition", err)
	}
	s.incoming <- ipc.Event{Control: &ipc.NativeMessage{Type: "capture_stopped", RequestID: stop.RequestID, SessionID: stop.SessionID,
		MicrophoneIOStopped: true, TapIOStopped: true, TapDestroyed: true, AggregateDestroyed: true}}
	select {
	case err := <-startDone:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("canceled dispatched start error = %v, want context.Canceled after closure ACK", err)
		}
	case <-time.After(time.Second):
		t.Fatal("startup did not finish after matching native stop ACK")
	}
	select {
	case err := <-muteDone:
		if err != nil {
			t.Fatalf("mute failed after confirmed closure: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("mute did not complete after closure ACK")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.muted || s.capturing || s.starting || !s.closureConfirmed {
		t.Fatalf("unsafe state after closure ACK: muted=%t capturing=%t starting=%t closure=%t", s.muted, s.capturing, s.starting, s.closureConfirmed)
	}
}

func TestNativeMuteClosureTimeoutReturnsCurrentConflict(t *testing.T) {
	cfg := config.Defaults()
	cfg.DrainTimeout = 40 * time.Millisecond
	s := newTestService(t, cfg, false)
	s.muted, s.capturing, s.closureConfirmed = false, true, false
	s.active = &activePair{ready: backend.Ready{DrainTimeoutMS: 40}}
	command := ipc.NativeMessage{Type: "native_set_muted", RequestID: "00112233-4455-6677-8899-aabbccddeeff", CommandSequence: 1, ExpectedStatusRevision: 1, Muted: true}
	started := time.Now()
	if err := s.applyNativeCommandAt(command, started); err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("mute exceeded bounded closure deadline: %v", elapsed)
	}
	s.mu.Lock()
	result := s.commands[1].result
	s.mu.Unlock()
	if result.Error == nil || result.Error.Code != "status_conflict" || result.Status == nil || result.Status.Capturing != true {
		t.Fatalf("timeout did not return correlated conflict with current status: %+v", result)
	}
}

func TestActivePairDemandIsIndependentOfIdleClosure(t *testing.T) {
	s := &Service{muted: false, closureConfirmed: false, clients: map[uint64]*subscriber{1: {}}, active: &activePair{}, changed: make(chan struct{}, 1)}
	s.mu.Lock()
	wantsAudio, canStart, updateReady := s.demandLocked(), s.canStartLocked(), s.updateReadyLocked()
	s.mu.Unlock()
	if !wantsAudio {
		t.Fatal("active paired session lost subscriber demand after capture_started")
	}
	if canStart {
		t.Fatal("relay admitted a second generation before closure confirmation")
	}
	if updateReady {
		t.Fatal("active generation was reported safe for update")
	}
}

func TestNativeEOFGentlyExitsOnlyFromConfirmedSafeIdle(t *testing.T) {
	newService := func() *Service { return newTestService(t, config.Defaults(), true) }

	safe := newService()
	safe.handleNativeEOF()
	safe.mu.Lock()
	clean, requested := safe.cleanNativeEOF, safe.shutdownRequested
	safe.mu.Unlock()
	if !clean || !requested {
		t.Fatal("confirmed muted idle EOF was not accepted as graceful shutdown")
	}
	go safe.supervise()
	select {
	case <-safe.shutdownDone:
	case <-time.After(time.Second):
		t.Fatal("safe EOF did not complete relay shutdown")
	}

	unsafe := newService()
	unsafe.mu.Lock()
	unsafe.muted = false
	unsafe.mu.Unlock()
	unsafe.handleNativeEOF()
	select {
	case <-unsafe.closed:
	case <-time.After(time.Second):
		t.Fatal("unsafe EOF did not fail closed")
	}
	unsafe.mu.Lock()
	clean, closed := unsafe.cleanNativeEOF, unsafe.closureConfirmed
	unsafe.mu.Unlock()
	if clean || closed {
		t.Fatal("unmuted native EOF was incorrectly accepted as safe idle")
	}
	select {
	case err := <-unsafe.fatal:
		if !errors.Is(err, ErrNativeDisconnected) {
			t.Fatalf("unexpected EOF failure: %v", err)
		}
	default:
		t.Fatal("unsafe EOF did not record native disconnect")
	}
}
