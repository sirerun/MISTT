package service

import (
	"log/slog"
	"time"
)

// IPC accepts forward-compatible codes, so never log a received code verbatim.
// Only these static native implementation enums may enter operational logs.
func startupNativeCode(code string) string {
	switch code {
	case "capture_start_failed", "closure_unconfirmed", "stop_timeout", "native_capture_failure",
		"shutdown", "busy", "relay_unavailable", "stale_session":
		return code
	default:
		return "unknown"
	}
}

// Deliberately accepts no error/message, configuration, or media value.
func logStartup(phase, class, nativeCode, sessionID string, elapsed time.Duration) {
	slog.Info("paired_startup", "phase", phase, "error_class", class,
		"native_code", nativeCode, "elapsed_ms", elapsed.Milliseconds(), "session_id", sessionID)
}
