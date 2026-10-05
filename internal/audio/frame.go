package audio

import (
	"encoding/binary"
	"errors"
	"fmt"
)

const (
	SampleRate = 16000
	Channels   = 1
	Encoding   = "s16le"
	HeaderSize = 52
	MaxSamples = 1600
	SampleNS   = uint64(62500)
)

type Source string

const (
	Microphone Source = "microphone"
	CallAudio  Source = "call_audio"
)

func (s Source) Valid() bool { return s == Microphone || s == CallAudio }
func (s Source) ID() byte {
	if s == Microphone {
		return 1
	}
	if s == CallAudio {
		return 2
	}
	return 0
}
func SourceFromID(id byte) (Source, error) {
	switch id {
	case 1:
		return Microphone, nil
	case 2:
		return CallAudio, nil
	default:
		return "", fmt.Errorf("unknown source ID %d", id)
	}
}

type Frame struct {
	SessionID       [16]byte
	Source          Source
	Sequence        uint64
	StartSample     uint64
	CaptureOffsetNS uint64
	Samples         []int16
}

func ParseUUID(text string) ([16]byte, error) {
	var out [16]byte
	if len(text) != 36 || text[8] != '-' || text[13] != '-' || text[18] != '-' || text[23] != '-' {
		return out, errors.New("session_id must be a canonical UUID")
	}
	j := 0
	for i := 0; i < len(text); i++ {
		if text[i] == '-' {
			continue
		}
		if j >= 32 {
			return out, errors.New("invalid UUID")
		}
		b, ok := hexNibble(text[i])
		if !ok {
			return out, errors.New("invalid UUID hex")
		}
		if j%2 == 0 {
			out[j/2] = b << 4
		} else {
			out[j/2] |= b
		}
		j++
	}
	if j != 32 {
		return out, errors.New("invalid UUID length")
	}
	return out, nil
}
func FormatUUID(id [16]byte) string {
	const h = "0123456789abcdef"
	var out [36]byte
	p := 0
	for i, b := range id {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out[p] = '-'
			p++
		}
		out[p] = h[b>>4]
		out[p+1] = h[b&15]
		p += 2
	}
	return string(out[:])
}
func hexNibble(b byte) (byte, bool) {
	switch {
	case b >= '0' && b <= '9':
		return b - '0', true
	case b >= 'a' && b <= 'f':
		return b - 'a' + 10, true
	case b >= 'A' && b <= 'F':
		return b - 'A' + 10, true
	default:
		return 0, false
	}
}

func (f Frame) Validate() error {
	var allZero bool = true
	for _, b := range f.SessionID {
		if b != 0 {
			allZero = false
			break
		}
	}
	if allZero {
		return errors.New("audio frame session UUID cannot be nil")
	}
	if !f.Source.Valid() {
		return errors.New("audio frame has invalid source")
	}
	if f.Sequence == 0 {
		return errors.New("audio frame sequence must be positive")
	}
	if len(f.Samples) == 0 || len(f.Samples) > MaxSamples {
		return fmt.Errorf("audio frame sample count must be 1..%d", MaxSamples)
	}
	if uint64(len(f.Samples)) > ^uint64(0)-f.StartSample {
		return errors.New("audio frame sample index overflows")
	}
	if f.CaptureOffsetNS > ^uint64(0)-f.SampleOffsetNS(len(f.Samples)-1) {
		return errors.New("audio frame sample timestamp overflows")
	}
	return nil
}
func (f Frame) SampleOffsetNS(index int) uint64 { return uint64(index) * SampleNS }

func (f Frame) MarshalBinary() ([]byte, error) {
	if err := f.Validate(); err != nil {
		return nil, err
	}
	out := make([]byte, HeaderSize+2*len(f.Samples))
	copy(out[:4], "MST1")
	copy(out[4:20], f.SessionID[:])
	out[20] = f.Source.ID()
	binary.BigEndian.PutUint64(out[24:32], f.Sequence)
	binary.BigEndian.PutUint64(out[32:40], f.StartSample)
	binary.BigEndian.PutUint64(out[40:48], f.CaptureOffsetNS)
	binary.BigEndian.PutUint32(out[48:52], uint32(len(f.Samples)))
	for i, s := range f.Samples {
		binary.LittleEndian.PutUint16(out[HeaderSize+i*2:], uint16(s))
	}
	return out, nil
}
func ParseFrame(data []byte) (Frame, error) {
	var f Frame
	if len(data) < HeaderSize {
		return f, errors.New("audio frame shorter than 52-byte header")
	}
	if string(data[:4]) != "MST1" {
		return f, errors.New("invalid audio frame magic")
	}
	if data[21] != 0 || data[22] != 0 || data[23] != 0 {
		return f, errors.New("audio frame reserved bytes must be zero")
	}
	copy(f.SessionID[:], data[4:20])
	source, err := SourceFromID(data[20])
	if err != nil {
		return f, err
	}
	f.Source = source
	f.Sequence = binary.BigEndian.Uint64(data[24:32])
	f.StartSample = binary.BigEndian.Uint64(data[32:40])
	f.CaptureOffsetNS = binary.BigEndian.Uint64(data[40:48])
	n := binary.BigEndian.Uint32(data[48:52])
	if n == 0 || n > MaxSamples {
		return f, fmt.Errorf("invalid audio frame sample count %d", n)
	}
	if len(data) != HeaderSize+int(n)*2 {
		return f, errors.New("audio frame payload length does not match sample count")
	}
	f.Samples = make([]int16, n)
	for i := range f.Samples {
		f.Samples[i] = int16(binary.LittleEndian.Uint16(data[HeaderSize+i*2:]))
	}
	if err := f.Validate(); err != nil {
		return Frame{}, err
	}
	return f, nil
}

func ParsePCM16LE(data []byte) ([]int16, error) {
	if len(data) == 0 || len(data)%2 != 0 {
		return nil, errors.New("PCM must contain a positive even number of bytes")
	}
	if len(data) > MaxSamples*2 {
		return nil, errors.New("PCM block exceeds 100ms")
	}
	v := make([]int16, len(data)/2)
	for i := range v {
		v[i] = int16(binary.LittleEndian.Uint16(data[i*2:]))
	}
	return v, nil
}
func ValidUUIDText(s string) bool { _, err := ParseUUID(s); return err == nil }
