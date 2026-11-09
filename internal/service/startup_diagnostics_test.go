package service

import (
	"bytes"
	"context"
	"errors"
	"log/slog"
	"strings"
	"testing"
	"time"

	"github.com/sirerun/MISTT/internal/backend"
	"github.com/sirerun/MISTT/internal/config"
	"github.com/sirerun/MISTT/internal/ipc"
)

func TestStartupDiagnosticsExcludePrivateFailures(t *testing.T) {
	const private = "private transcript token /private/audio.wav"
	for _, tc := range []struct{ name, code, phase, loggedCode string }{
		{"backend", "", "backend_connect", ""},
		{"readiness", "invalid_ready", "backend_readiness", ""},
		{"native", "capture_start_failed", "native_start", "capture_start_failed"},
		{"unrecognized native code", private, "native_start", "unknown"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var logs bytes.Buffer
			previous := slog.Default()
			slog.SetDefault(slog.New(slog.NewJSONHandler(&logs, nil)))
			defer slog.SetDefault(previous)
			provider := providerFunc(func(_ context.Context, req backend.StartRequest) (backend.Session, error) {
				if tc.code == "" {
					return nil, errors.New(private)
				}
				if tc.code == "invalid_ready" {
					return &inertSession{}, nil
				}
				return &inertSession{ready: backend.Ready{SessionID: req.SessionID, Language: req.Language, Model: private}}, nil
			})
			s, reader := serviceWithOutputReader(t, config.Defaults(), provider)
			s.muted = false
			s.clients[1] = &subscriber{id: 1}
			done := make(chan error, 1)
			go func() { done <- s.startPair() }()
			if tc.code != "" && tc.code != "invalid_ready" {
				start := readNativeCommand(t, reader)
				s.incoming <- ipc.Event{Control: &ipc.NativeMessage{Type: "capture_failed", SessionID: start.SessionID, Code: tc.code, Detail: private, ClosureConfirmed: true}}
			}
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("expected startup failure")
				}
			case <-time.After(2 * time.Second):
				t.Fatal("startup did not finish")
			}
			got := logs.String()
			if strings.Contains(got, private) {
				t.Fatalf("private data entered diagnostics: %s", got)
			}
			for _, want := range []string{`"phase":"` + tc.phase + `"`, `"error_class":"failure"`, `"native_code":"` + tc.loggedCode + `"`, `"session_id":"`, `"elapsed_ms":`} {
				if !strings.Contains(got, want) {
					t.Fatalf("missing %s in %s", want, got)
				}
			}
		})
	}
}

func TestStartupNativeCodeWhitelist(t *testing.T) {
	for _, code := range []string{"capture_start_failed", "closure_unconfirmed", "stop_timeout", "native_capture_failure", "shutdown", "busy", "relay_unavailable", "stale_session"} {
		if got := startupNativeCode(code); got != code {
			t.Fatalf("%s mapped to %s", code, got)
		}
	}
	for _, code := range []string{"", "capture_start_failed private", "CAPTURE_START_FAILED", "token=secret"} {
		if got := startupNativeCode(code); got != "unknown" {
			t.Fatalf("unlisted code mapped to %s", got)
		}
	}
}
