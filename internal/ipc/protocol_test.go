package ipc

import (
	"bytes"
	"encoding/binary"
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

func TestFramedReaderDecodesControlAndMST1(t *testing.T) {
	id, _ := audio.ParseUUID("00112233-4455-6677-8899-aabbccddeeff")
	frame, err := (audio.Frame{SessionID: id, Source: audio.CallAudio, Sequence: 1, Samples: []int16{4, -4}}).MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	control := []byte(`{"type":"heartbeat","counter":1}`)
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

func TestFramedReaderRejectsUnknownKindsAndOversizedLength(t *testing.T) {
	for _, wire := range [][]byte{{0, 0, 0, 1, 9}, {0, 1, 0, 0}} {
		r := NewReader(bytes.NewReader(wire))
		if _, err := r.ReadEvent(); err == nil {
			t.Fatalf("accepted malformed frame %x", wire)
		}
	}
}
