package service

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/gorilla/websocket"
	"github.com/sirerun/MISTT/internal/audio"
	"strings"
	"testing"
	"time"
)

func TestRolloverDiagnosticsClassifiesOnlyKnownCauses(t *testing.T) {
	tests := []struct {
		err  error
		want string
	}{{nil, "interrupted"}, {context.DeadlineExceeded, "deadline"}, {ErrNativeDisconnected, "native_disconnected"}, {errors.New("DGX transcript end sample and offset disagree"), "transcript_end_clock_mismatch"}, {fmt.Errorf("wrapper: %w", errors.New("DGX transcript start sample and offset disagree")), "transcript_start_clock_mismatch"}, {fmt.Errorf("DGX stream read: %w", &websocket.CloseError{Code: 1011, Text: "arbitrary fictional transcript secret"}), "remote_close_backend"}, {errors.New("arbitrary fictional transcript secret"), "unclassified"}}
	for _, x := range tests {
		if got := rolloverCause(x.err); got != x.want {
			t.Fatalf("got%s want%s", got, x.want)
		}
	}
}
func TestRolloverDiagnosticSinkCannotBlockOrLeakErrorText(t *testing.T) {
	s := &Service{}
	p := &activePair{sequence: 81, remoteOffsetNS: 110000000000, ledgers: map[audio.Source]*sourceLedger{audio.Microphone: {nextSample: 3520000}, audio.CallAudio: {nextSample: 3520000}}}
	sink := make(chan RolloverDiagnostic, 1)
	s.SetRolloverDiagnostics(sink)
	marker := "arbitrary fictional transcript secret"
	s.reportRollover(p, "old_transcript_validation", 220000000000, errors.New(marker))
	d := <-sink
	b, _ := json.Marshal(d)
	if strings.Contains(string(b), marker) || d.Cause != "unclassified" || d.NativeSamples[0] != 3520000 {
		t.Fatal("unsafe diagnostic")
	}
	sink <- d
	done := make(chan struct{})
	go func() { s.reportRollover(p, "old_settlement", 0, context.DeadlineExceeded); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("diagnostics delayed cleanup")
	}
	s.SetRolloverDiagnostics(nil)
}
