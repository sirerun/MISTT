package ipc

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"unicode/utf8"

	"github.com/sirerun/MISTT/internal/audio"
)

const MaxControlLine = 64 << 10
const MaxFrameBytes = audio.HeaderSize + audio.MaxSamples*2

type SourceFormat struct {
	Source       audio.Source `json:"source"`
	SampleRateHz uint32       `json:"sample_rate_hz"`
	Channels     uint32       `json:"channels"`
	Encoding     string       `json:"encoding"`
}

func (f SourceFormat) Valid(want audio.Source) bool {
	return f.Source == want && f.SampleRateHz == audio.SampleRate && f.Channels == audio.Channels && f.Encoding == audio.Encoding
}

// NativeMessage is the typed Go representation of the versioned native-control schema.
// Fields are validated against the message-specific key set before this is returned.
type NativeMessage struct {
	Type                     string         `json:"type"`
	RequestID                string         `json:"request_id,omitempty"`
	SessionID                string         `json:"session_id,omitempty"`
	Reason                   string         `json:"reason,omitempty"`
	Code                     string         `json:"code,omitempty"`
	Detail                   string         `json:"detail,omitempty"`
	Sources                  []SourceFormat `json:"sources,omitempty"`
	MicrophoneReady          bool           `json:"microphone_ready,omitempty"`
	CallAudioReady           bool           `json:"call_audio_ready,omitempty"`
	CaptureEpochHostNS       uint64         `json:"capture_epoch_host_ns,omitempty"`
	CaptureEpochUnixMS       int64          `json:"capture_epoch_unix_ms,omitempty"`
	CutoffHostNS             uint64         `json:"cutoff_host_ns,omitempty"`
	MicrophoneIOStopped      bool           `json:"microphone_io_stopped,omitempty"`
	TapIOStopped             bool           `json:"tap_io_stopped,omitempty"`
	TapDestroyed             bool           `json:"tap_destroyed,omitempty"`
	AggregateDestroyed       bool           `json:"aggregate_destroyed,omitempty"`
	ClosureConfirmed         bool           `json:"closure_confirmed,omitempty"`
	Source                   audio.Source   `json:"source,omitempty"`
	LastSequence             uint64         `json:"last_sequence,omitempty"`
	TotalSamples             uint64         `json:"total_samples,omitempty"`
	CommandSequence          uint64         `json:"command_sequence,omitempty"`
	ExpectedStatusRevision   uint64         `json:"expected_status_revision,omitempty"`
	Muted                    bool           `json:"muted,omitempty"`
	Counter                  uint64         `json:"counter,omitempty"`
	ConnectedClients         uint32         `json:"connected_clients,omitempty"`
	Capturing                bool           `json:"capturing,omitempty"`
	Revision                 uint64         `json:"revision,omitempty"`
	UpdateReady              bool           `json:"update_ready,omitempty"`
	UpdateReserved           bool           `json:"update_reserved,omitempty"`
	Status                   *NativeStatus  `json:"status,omitempty"`
	Error                    *NativeError   `json:"error,omitempty"`
	Device                   string         `json:"device,omitempty"`
	BundleID                 string         `json:"bundle_id,omitempty"`
	IncludeHelpers           []uint32       `json:"include_helpers,omitempty"`
	IncludeHelperExecutables []string       `json:"include_helper_executables,omitempty"`
}

func (m NativeMessage) MarshalJSON() ([]byte, error) {
	var value map[string]any
	switch m.Type {
	case "capture_start":
		helpers := m.IncludeHelpers
		if helpers == nil {
			helpers = []uint32{}
		}
		executables := m.IncludeHelperExecutables
		if executables == nil {
			executables = []string{}
		}
		value = map[string]any{"type": m.Type, "request_id": m.RequestID, "session_id": m.SessionID, "sources": m.Sources, "microphone": map[string]any{"device": m.Device}, "call_audio": map[string]any{"bundle_id": m.BundleID, "include_helpers": helpers, "include_helper_executables": executables}}
	case "capture_stop":
		value = map[string]any{"type": m.Type, "request_id": m.RequestID, "session_id": m.SessionID, "reason": m.Reason}
	case "native_set_muted":
		value = map[string]any{"type": m.Type, "request_id": m.RequestID, "command_sequence": m.CommandSequence, "expected_status_revision": m.ExpectedStatusRevision, "muted": m.Muted}
	case "native_prepare_update", "native_cancel_update":
		value = map[string]any{"type": m.Type, "request_id": m.RequestID, "command_sequence": m.CommandSequence, "expected_status_revision": m.ExpectedStatusRevision}
	case "control_result":
		value = map[string]any{"type": m.Type, "request_id": m.RequestID, "status": m.Status, "error": m.Error}
	case "status":
		value = map[string]any{"type": m.Type, "muted": m.Muted, "capturing": m.Capturing, "connected_clients": m.ConnectedClients, "reason": m.Reason, "revision": m.Revision, "update_ready": m.UpdateReady, "update_reserved": m.UpdateReserved}
	default:
		return nil, fmt.Errorf("cannot encode unsupported native message type %q", m.Type)
	}
	return json.Marshal(value)
}

type NativeStatus struct {
	Muted            bool   `json:"muted"`
	Capturing        bool   `json:"capturing"`
	ConnectedClients uint32 `json:"connected_clients"`
	Reason           string `json:"reason"`
	Revision         uint64 `json:"revision"`
	UpdateReady      bool   `json:"update_ready"`
	UpdateReserved   bool   `json:"update_reserved"`
}
type NativeError struct {
	Code   string `json:"code"`
	Detail string `json:"detail"`
}

type Event struct {
	Control *NativeMessage
	Frame   *audio.Frame
}

var controlKeys = map[string]map[string]bool{
	"capture_started":       keys("type request_id session_id capture_epoch_host_ns capture_epoch_unix_ms sources microphone_ready call_audio_ready"),
	"capture_stopped":       keys("type request_id session_id cutoff_host_ns microphone_io_stopped tap_io_stopped tap_destroyed aggregate_destroyed"),
	"capture_failed":        keys("type request_id session_id code detail closure_confirmed"),
	"source_end":            keys("type session_id source last_sequence total_samples"),
	"native_set_muted":      keys("type request_id command_sequence expected_status_revision muted"),
	"native_prepare_update": keys("type request_id command_sequence expected_status_revision"),
	"native_cancel_update":  keys("type request_id command_sequence expected_status_revision"),
	"heartbeat":             keys("type counter"),
}

func keys(s string) map[string]bool {
	m := map[string]bool{}
	for _, k := range strings.Fields(s) {
		m[k] = true
	}
	return m
}

var requiredKeys = map[string][]string{
	"capture_started":       {"type", "request_id", "session_id", "capture_epoch_host_ns", "capture_epoch_unix_ms", "sources", "microphone_ready", "call_audio_ready"},
	"capture_stopped":       {"type", "request_id", "session_id", "cutoff_host_ns", "microphone_io_stopped", "tap_io_stopped", "tap_destroyed", "aggregate_destroyed"},
	"capture_failed":        {"type", "session_id", "code", "detail", "closure_confirmed"},
	"source_end":            {"type", "session_id", "source", "last_sequence", "total_samples"},
	"native_set_muted":      {"type", "request_id", "command_sequence", "expected_status_revision", "muted"},
	"native_prepare_update": {"type", "request_id", "command_sequence", "expected_status_revision"},
	"native_cancel_update":  {"type", "request_id", "command_sequence", "expected_status_revision"},
	"heartbeat":             {"type", "counter"},
}

func DecodeControl(line []byte) (NativeMessage, error) {
	var msg NativeMessage
	if !utf8.Valid(line) {
		return msg, errors.New("native control is not valid UTF-8")
	}
	fields, err := decodeUniqueObject(line)
	if err != nil {
		return msg, err
	}
	typeRaw, ok := fields["type"]
	if !ok {
		return msg, errors.New("native control is missing type")
	}
	if err := json.Unmarshal(typeRaw, &msg.Type); err != nil || msg.Type == "" {
		return msg, errors.New("native control type must be a nonempty string")
	}
	allowed, ok := controlKeys[msg.Type]
	if !ok {
		return msg, fmt.Errorf("unknown native control type %q", msg.Type)
	}
	for name := range fields {
		if !allowed[name] {
			return msg, fmt.Errorf("field %q is not allowed for %s", name, msg.Type)
		}
		if bytes.Equal(bytes.TrimSpace(fields[name]), []byte("null")) {
			return msg, fmt.Errorf("native field %q cannot be null", name)
		}
	}
	for _, name := range requiredKeys[msg.Type] {
		if _, ok := fields[name]; !ok {
			return msg, fmt.Errorf("%s is missing required field %q", msg.Type, name)
		}
	}
	dec := json.NewDecoder(bytes.NewReader(line))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&msg); err != nil {
		return NativeMessage{}, fmt.Errorf("decode native %s: %w", msg.Type, err)
	}
	if err := msg.Validate(); err != nil {
		return NativeMessage{}, err
	}
	return msg, nil
}
func decodeUniqueObject(data []byte) (map[string]json.RawMessage, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	tok, err := dec.Token()
	if err != nil || tok != json.Delim('{') {
		return nil, errors.New("native control must be a JSON object")
	}
	fields := map[string]json.RawMessage{}
	for dec.More() {
		tok, err = dec.Token()
		if err != nil {
			return nil, err
		}
		key, ok := tok.(string)
		if !ok {
			return nil, errors.New("invalid JSON object key")
		}
		if _, exists := fields[key]; exists {
			return nil, fmt.Errorf("duplicate JSON field %q", key)
		}
		var raw json.RawMessage
		if err := dec.Decode(&raw); err != nil {
			return nil, err
		}
		fields[key] = raw
	}
	if _, err = dec.Token(); err != nil {
		return nil, err
	}
	if _, err = dec.Token(); err != io.EOF {
		return nil, errors.New("trailing JSON after native control")
	}
	return fields, nil
}
func (m NativeMessage) Validate() error {
	if m.RequestID != "" && !audio.ValidUUIDText(m.RequestID) {
		return errors.New("native request_id is not a UUID")
	}
	if m.SessionID != "" && !audio.ValidUUIDText(m.SessionID) {
		return errors.New("native session_id is not a UUID")
	}
	switch m.Type {
	case "capture_started":
		if m.CaptureEpochHostNS == 0 || m.CaptureEpochUnixMS <= 0 {
			return errors.New("capture_started requires positive host and wall-clock epochs")
		}
		if !m.MicrophoneReady || !m.CallAudioReady || len(m.Sources) != 2 || !m.Sources[0].Valid(audio.Microphone) || !m.Sources[1].Valid(audio.CallAudio) {
			return errors.New("capture_started requires both canonical 16 kHz mono s16le sources ready")
		}
	case "capture_stopped":
		if !m.MicrophoneIOStopped || !m.TapIOStopped || !m.TapDestroyed || !m.AggregateDestroyed {
			return errors.New("capture_stopped does not confirm paired resource closure")
		}
	case "capture_failed":
		if m.Code == "" {
			return errors.New("capture_failed requires a sanitized code")
		}
	case "source_end":
		if !m.Source.Valid() {
			return errors.New("source_end has an unknown source")
		}
		if (m.LastSequence == 0) != (m.TotalSamples == 0) {
			return errors.New("empty source_end must have zero sequence and sample total")
		}
	case "native_set_muted", "native_prepare_update", "native_cancel_update":
		if m.CommandSequence == 0 {
			return errors.New("native command sequence must be positive")
		}
		if m.ExpectedStatusRevision == 0 {
			return errors.New("native command expected_status_revision must be positive")
		}
	case "heartbeat":
		if m.Counter == 0 {
			return errors.New("heartbeat counter must be positive")
		}
	}
	return nil
}
