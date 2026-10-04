package ipc

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"

	"github.com/sirerun/MISTT/internal/audio"
)

type Reader struct{ r *bufio.Reader }

func NewReader(r io.Reader) *Reader {
	return &Reader{r: bufio.NewReaderSize(r, MaxFrameBytes+MaxControlLine)}
}
func (r *Reader) ReadEvent() (Event, error) {
	var out Event
	var prefix [4]byte
	if _, err := io.ReadFull(r.r, prefix[:]); err != nil {
		if err == io.EOF {
			return out, io.EOF
		}
		return out, fmt.Errorf("read native IPC length: %w", err)
	}
	n := binary.BigEndian.Uint32(prefix[:])
	if n == 0 || n > MaxControlLine+1 {
		return out, fmt.Errorf("native IPC frame length %d is outside bounds", n)
	}
	kind, err := r.r.ReadByte()
	if err != nil {
		return out, fmt.Errorf("read native IPC kind: %w", err)
	}
	bodyLimit := MaxControlLine
	if kind == 2 {
		bodyLimit = MaxFrameBytes
	} else if kind != 1 {
		return out, fmt.Errorf("unknown native IPC kind %d", kind)
	}
	if n-1 > uint32(bodyLimit) {
		return out, fmt.Errorf("native IPC kind %d payload exceeds %d bytes", kind, bodyLimit)
	}
	body := make([]byte, int(n-1))
	if _, err := io.ReadFull(r.r, body); err != nil {
		return out, fmt.Errorf("read native IPC payload: %w", err)
	}
	if kind == 2 {
		frame, err := audio.ParseFrame(body)
		if err != nil {
			return out, err
		}
		out.Frame = &frame
		return out, nil
	}
	if !bytes.HasSuffix(body, []byte("\n")) {
		return out, errors.New("native JSON control must end with LF")
	}
	msg, err := DecodeControl(bytes.TrimSpace(body))
	if err != nil {
		return out, err
	}
	out.Control = &msg
	return out, nil
}
