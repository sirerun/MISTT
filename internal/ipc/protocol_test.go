package ipc

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"testing"

	"github.com/sirerun/MISTT/internal/audio"
)

func TestDecodeControlStrictFieldsAndCorrelation(t *testing.T) {
	good := []byte(`{"type":"native_prepare_update","request_id":"00112233-4455-6677-8899-aabbccddeeff","command_sequence":1,"expected_status_revision":8}`)
	m, err := DecodeControl(good)
	if err != nil {
		t.Fatal(err)
	}
	if m.CommandSequence != 1 || m.ExpectedStatusRevision != 8 {
		t.Fatalf("decoded wrong command: %+v", m)
	}
	bad := [][]byte{
		[]byte(`{"type":"native_prepare_update","request_id":"00112233-4455-6677-8899-aabbccddeeff","command_sequence":1,"expected_status_revision":8,"unknown":true}`),
		[]byte(`{"type":"native_prepare_update","type":"native_prepare_update","request_id":"00112233-4455-6677-8899-aabbccddeeff","command_sequence":1,"expected_status_revision":8}`),
		[]byte(`{"type":"native_prepare_update","request_id":null,"command_sequence":1,"expected_status_revision":8}`),
		[]byte(`{"type":"native_prepare_update","request_id":"00112233-4455-6677-8899-aabbccddeeff","command_sequence":0,"expected_status_revision":8}`),
		[]byte(`{"type":"native_cancel_update","request_id":"00112233-4455-6677-8899-aabbccddeeff","command_sequence":1}`),
	}
	for _, b := range bad {
		if _, err := DecodeControl(b); err == nil {
			t.Fatalf("accepted malformed control: %s", b)
		}
	}
}

func TestFoundationUppercaseUUIDsNormalizeForNativeCorrelation(t *testing.T) {
	requestUpper := "10112233-4455-6677-8899-AABBCCDDEEFF"
	sessionUpper := "00112233-4455-6677-8899-AABBCCDDEEFF"
	cases := []struct{ name, raw string }{
		{"capture started", `{"type":"capture_started","request_id":"` + requestUpper + `","session_id":"` + sessionUpper + `","capture_epoch_host_ns":10,"capture_epoch_unix_ms":20,"sources":[{"source":"microphone","sample_rate_hz":16000,"channels":1,"encoding":"s16le"},{"source":"call_audio","sample_rate_hz":16000,"channels":1,"encoding":"s16le"}],"microphone_ready":true,"call_audio_ready":true}`},
		{"capture stopped", `{"type":"capture_stopped","request_id":"` + requestUpper + `","session_id":"` + sessionUpper + `","cutoff_host_ns":30,"microphone_io_stopped":true,"tap_io_stopped":true,"tap_destroyed":true,"aggregate_destroyed":true}`},
		{"source end", `{"type":"source_end","session_id":"` + sessionUpper + `","source":"microphone","last_sequence":0,"total_samples":0}`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m, err := DecodeControl([]byte(tc.raw))
			if err != nil {
				t.Fatal(err)
			}
			if m.SessionID != "00112233-4455-6677-8899-aabbccddeeff" {
				t.Fatalf("session ID not canonicalized: %q", m.SessionID)
			}
			if m.RequestID != "" && m.RequestID != "10112233-4455-6677-8899-aabbccddeeff" {
				t.Fatalf("request ID not canonicalized: %q", m.RequestID)
			}
		})
	}
}

func TestOutboundZeroValueFieldsKeepSchemaTypes(t *testing.T) {
	status, err := json.Marshal(NativeMessage{Type: "status", Reason: "startup_muted", Revision: 1})
	if err != nil {
		t.Fatal(err)
	}
	var snapshot map[string]any
	if err := json.Unmarshal(status, &snapshot); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"muted", "capturing", "connected_clients", "update_ready", "update_reserved"} {
		if _, ok := snapshot[key]; !ok {
			t.Fatalf("status omitted required zero field %q: %s", key, status)
		}
	}
	if snapshot["muted"] != false || snapshot["capturing"] != false || snapshot["connected_clients"] != float64(0) || snapshot["update_reserved"] != false {
		t.Fatalf("status zero fields changed type/value: %s", status)
	}
	start, err := json.Marshal(NativeMessage{Type: "capture_start", RequestID: "00112233-4455-6677-8899-aabbccddeeff", SessionID: "10112233-4455-6677-8899-aabbccddeeff", Sources: []SourceFormat{{Source: audio.Microphone, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}, {Source: audio.CallAudio, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}}})
	if err != nil {
		t.Fatal(err)
	}
	var command struct {
		CallAudio struct {
			IncludeHelpers     []uint32 `json:"include_helpers"`
			IncludeExecutables []string `json:"include_helper_executables"`
		} `json:"call_audio"`
	}
	if err := json.Unmarshal(start, &command); err != nil {
		t.Fatal(err)
	}
	if command.CallAudio.IncludeHelpers == nil || command.CallAudio.IncludeExecutables == nil {
		t.Fatalf("empty helper lists must be arrays, got %s", start)
	}
}

func TestFramedReaderDecodesControlAndMST1(t *testing.T) {
	id, _ := audio.ParseUUID("00112233-4455-6677-8899-aabbccddeeff")
	frame, err := (audio.Frame{SessionID: id, Source: audio.CallAudio, Sequence: 1, Samples: []int16{4, -4}}).MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	control := []byte(`{"type":"heartbeat","counter":1}` + "\n")
	var wire bytes.Buffer
	write := func(kind byte, payload []byte) {
		binary.Write(&wire, binary.BigEndian, uint32(len(payload)+1))
		wire.WriteByte(kind)
		wire.Write(payload)
	}
	write(1, control)
	write(2, frame)
	r := NewReader(&wire)
	e, err := r.ReadEvent()
	if err != nil || e.Control == nil || e.Control.Counter != 1 {
		t.Fatalf("control event=%+v err=%v", e, err)
	}
	e, err = r.ReadEvent()
	if err != nil || e.Frame == nil || e.Frame.Source != audio.CallAudio || e.Frame.Samples[1] != -4 {
		t.Fatalf("frame event=%+v err=%v", e, err)
	}
}

func TestFramedReaderRequiresControlLF(t *testing.T) {
	control := []byte(`{"type":"heartbeat","counter":1}`)
	var wire bytes.Buffer
	binary.Write(&wire, binary.BigEndian, uint32(len(control)+1))
	wire.WriteByte(1)
	wire.Write(control)
	if _, err := NewReader(&wire).ReadEvent(); err == nil {
		t.Fatal("accepted control event without its required LF terminator")
	}
}

func TestFramedReaderRejectsUnknownKindsAndOversizedLength(t *testing.T) {
	for _, wire := range [][]byte{{0, 0, 0, 1, 9}, {0, 1, 0, 0}} {
		r := NewReader(bytes.NewReader(wire))
		if _, err := r.ReadEvent(); err == nil {
			t.Fatalf("accepted malformed frame %x", wire)
		}
	}
}
