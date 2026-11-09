package service

import (
	"context"
	"errors"
	"github.com/gorilla/websocket"
	"github.com/sirerun/MISTT/internal/audio"
	"net"
)

// RolloverDiagnostic is opt-in internal debug evidence. It never carries error
// messages, transcript/audio, credentials or native identifiers. Public status,
// native IPC and transcript protocol remain unchanged.
type RolloverDiagnostic struct {
	Event          string    `json:"event"`
	Version        int       `json:"version"`
	Stage          string    `json:"stage"`
	Cause          string    `json:"cause"`
	Sequence       uint64    `json:"sequence"`
	RemoteOffsetNS uint64    `json:"remote_offset_ns"`
	CutOffsetNS    uint64    `json:"cut_offset_ns"`
	NativeSamples  [2]uint64 `json:"native_samples"`
	RemoteSamples  [2]uint64 `json:"remote_samples"`
}

// SetRolloverDiagnostics must be configured before Run. The caller owns the
// channel and must not close it while the service is active. A full/unread channel
// cannot delay failure cleanup or native stop.
func (s *Service) SetRolloverDiagnostics(sink chan<- RolloverDiagnostic) {
	s.diagnosticMu.Lock()
	s.diagnostics = sink
	s.diagnosticMu.Unlock()
}
func (s *Service) reportRollover(pair *activePair, stage string, cut uint64, err error) {
	s.diagnosticMu.RLock()
	sink := s.diagnostics
	s.diagnosticMu.RUnlock()
	if sink == nil {
		return
	}
	d := RolloverDiagnostic{Event: "mistt_rollover_terminal", Version: 1, Stage: stage, Cause: rolloverCause(err), Sequence: pair.sequence, RemoteOffsetNS: pair.remoteOffsetNS, CutOffsetNS: cut}
	for i, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		if l := pair.ledgers[source]; l != nil {
			d.NativeSamples[i] = l.nextSample
		}
		if l := pair.transmittedLedger(source); l != nil {
			d.RemoteSamples[i] = l.nextSample
		}
	}
	select {
	case sink <- d:
	default:
	}
}
func rolloverCause(err error) string {
	if err == nil {
		return "interrupted"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "deadline"
	}
	if errors.Is(err, ErrNativeDisconnected) {
		return "native_disconnected"
	}
	// Exact equality deliberately excludes arbitrary backend/native detail. No
	// unknown string or wrapped message is emitted; stage still locates the failure.
	var closed *websocket.CloseError
	if errors.As(err, &closed) {
		switch closed.Code {
		case 1000:
			return "remote_close_normal"
		case 1001:
			return "remote_close_going_away"
		case 1006:
			return "remote_close_abnormal"
		case 1008:
			return "remote_close_policy"
		case 1011:
			return "remote_close_backend"
		default:
			return "remote_close_other"
		}
	}
	var network net.Error
	if errors.As(err, &network) {
		if network.Timeout() {
			return "network_timeout"
		}
		return "network_failure"
	}
	for depth := 0; err != nil && depth < 8; depth++ {
		if code, ok := rolloverCauses[err.Error()]; ok {
			return code
		}
		err = errors.Unwrap(err)
	}
	return "unclassified"
}

var rolloverCauses = map[string]string{
	"rollover has no paired native timeline":                 "missing_native_timeline",
	"rollover source clock overflows":                        "native_clock_overflow",
	"rollover cut overflows":                                 "cut_overflow",
	"rollover PCM capacity exceeded":                         "pcm_capacity",
	"rollover cut deadline exceeded":                         "cut_deadline",
	"rollover settlement deadline exceeded":                  "settlement_deadline",
	"rollover admission deadline exceeded":                   "admission_deadline",
	"old ASR ended before cut":                               "old_ended_before_cut",
	"old ASR closed without settlement":                      "old_closed_unsettled",
	"missing cut ledger":                                     "missing_cut_ledger",
	"DGX transcript has invalid source or sample interval":   "transcript_interval_invalid",
	"DGX transcript starts beyond retained source samples":   "transcript_start_after_sent",
	"DGX transcript refers to an empty source timeline":      "transcript_empty_timeline",
	"DGX transcript starts before retained sample timeline":  "transcript_start_before_sent",
	"clipped transcript offset overflows":                    "transcript_offset_overflow",
	"DGX transcript end sample and offset disagree":          "transcript_end_clock_mismatch",
	"DGX transcript starts outside retained sample timeline": "transcript_start_outside_sent",
	"DGX transcript start sample and offset disagree":        "transcript_start_clock_mismatch",
	"clipped transcript interval is invalid":                 "transcript_clipped_interval",
	"DGX changed a finalized transcript segment":             "transcript_after_final",
	"native transcript projection overflows":                 "transcript_projection_overflow",
	"transcript host offset overflows":                       "transcript_host_overflow",
	"transcript end host offset overflows":                   "transcript_end_host_overflow",
	"native sample offset overflows":                         "native_sample_offset_overflow",
	"native sample index and capture offset disagree":        "native_clock_mismatch",
	"native host timestamp overflows":                        "native_host_overflow",
	"native frame precedes remote origin":                    "frame_before_remote_origin",
	"missing remote source origin":                           "missing_remote_origin",
	"invalid old ASR source settlement":                      "invalid_source_completion",
	"old ASR done before paired settlement":                  "done_before_sources",
	"successor ASR contract changed":                         "successor_contract_changed",
	"successor audio budget expired during handoff":          "successor_budget_expired",
	"rollover requires paired native cursors":                "missing_paired_cursors",
	"rollover cursor does not cover cut boundary":            "cursor_does_not_cover_cut",
	"rollover buffer closed":                                 "buffer_closed",
	"rollover handoff deadline exceeded":                     "handoff_deadline",
	"rollover requires a fresh remote generation":            "remote_generation_invalid",
	"rollover requires both source ledgers":                  "missing_source_ledgers",
	"invalid rollover PCM":                                   "invalid_pcm",
	"rollover native provenance mismatch":                    "native_provenance_mismatch",
	"rollover first frame does not match cut cursor":         "first_frame_cursor_mismatch",
	"rollover native ledger gap":                             "native_ledger_gap",
	"rollover native ledger overflow":                        "native_ledger_overflow",
	"paired native continuation is not proven":               "continuation_unproven",
	"DGX transcript fields are invalid":                      "remote_transcript_fields_invalid",
	"DGX overall done before both source_done results":       "remote_done_before_sources",
	"DGX event queue overflow":                               "remote_event_queue_overflow",
}
