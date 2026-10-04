package audio

import (
	"bytes"
	"encoding/binary"
	"testing"
)

func TestMST1RoundTripAndWireFields(t *testing.T) {
	id, err := ParseUUID("00112233-4455-6677-8899-aabbccddeeff")
	if err != nil {
		t.Fatal(err)
	}
	want := Frame{SessionID: id, Source: CallAudio, Sequence: 7, StartSample: 320, CaptureOffsetNS: 20_000_000, Samples: []int16{-32768, -1, 0, 32767}}
	wire, err := want.MarshalBinary()
	if err != nil {
		t.Fatal(err)
	}
	if len(wire) != HeaderSize+8 || string(wire[:4]) != "MST1" || wire[20] != 2 {
		t.Fatalf("bad header: %x", wire[:HeaderSize])
	}
	if binary.BigEndian.Uint64(wire[24:32]) != 7 || binary.BigEndian.Uint64(wire[32:40]) != 320 || binary.BigEndian.Uint32(wire[48:52]) != 4 {
		t.Fatal("bad big endian ledger fields")
	}
	if !bytes.Equal(wire[HeaderSize:], []byte{0, 128, 255, 255, 0, 0, 255, 127}) {
		t.Fatalf("PCM is not s16le: %x", wire[HeaderSize:])
	}
	got, err := ParseFrame(wire)
	if err != nil {
		t.Fatal(err)
	}
	if got.Source != want.Source || got.Sequence != want.Sequence || got.StartSample != want.StartSample || got.CaptureOffsetNS != want.CaptureOffsetNS || len(got.Samples) != len(want.Samples) {
		t.Fatalf("round trip mismatch: %+v", got)
	}
	for i := range want.Samples {
		if got.Samples[i] != want.Samples[i] {
			t.Fatalf("sample %d mismatch", i)
		}
	}
}

func TestParseFrameRejectsMalformedWire(t *testing.T) {
	id, _ := ParseUUID("00112233-4455-6677-8899-aabbccddeeff")
	base, _ := (Frame{SessionID: id, Source: Microphone, Sequence: 1, Samples: []int16{1}}).MarshalBinary()
	cases := map[string]func([]byte) []byte{
		"magic":    func(b []byte) []byte { b[0] = 'X'; return b },
		"reserved": func(b []byte) []byte { b[21] = 1; return b },
		"source":   func(b []byte) []byte { b[20] = 9; return b },
		"count":    func(b []byte) []byte { binary.BigEndian.PutUint32(b[48:52], 0); return b },
		"length":   func(b []byte) []byte { return b[:len(b)-1] },
		"nil uuid": func(b []byte) []byte { clear(b[4:20]); return b },
		"sequence": func(b []byte) []byte { clear(b[24:32]); return b },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			b := mutate(append([]byte(nil), base...))
			if _, err := ParseFrame(b); err == nil {
				t.Fatal("accepted malformed frame")
			}
		})
	}
}
