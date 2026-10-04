package service

import (
	"context"
	"net"
	"os"
	"testing"
	"time"

	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"
	"github.com/sirerun/MISTT/internal/config"
	"github.com/sirerun/MISTT/internal/ipc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

func TestRealGRPCStatusAndRevisionGuard(t *testing.T) {
	readEnd, writeEnd, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer readEnd.Close()
	defer writeEnd.Close()
	s := New(config.Config{}, nil, nil, ipc.NewWriter(writeEnd, 8))
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

func TestNativeUpdateReservationAndCommandReplay(t *testing.T) {
	readEnd, writeEnd, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer readEnd.Close()
	defer writeEnd.Close()
	s := New(config.Config{}, nil, nil, ipc.NewWriter(writeEnd, 8))
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
