package ipc

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"syscall"
	"time"
)

var ErrControlQueueFull = errors.New("native control output queue is full")

type Writer struct {
	control chan NativeMessage
	status  chan NativeMessage
	failed  chan error
}

func NewWriter(out *os.File, capacity int) *Writer {
	if capacity < 1 {
		capacity = 32
	}
	w := &Writer{control: make(chan NativeMessage, capacity), status: make(chan NativeMessage, 1), failed: make(chan error, 1)}
	go w.run(out)
	return w
}
func (w *Writer) Failed() <-chan error { return w.failed }
func (w *Writer) SendControl(m NativeMessage) error {
	select {
	case w.control <- m:
		return nil
	default:
		return ErrControlQueueFull
	}
}
func (w *Writer) SendStatus(m NativeMessage) {
	select {
	case w.status <- m:
	default:
		select {
		case <-w.status:
		default:
		}
		select {
		case w.status <- m:
		default:
		}
	}
}
func (w *Writer) run(out *os.File) {
	if err := syscall.SetNonblock(int(out.Fd()), true); err != nil {
		w.failed <- fmt.Errorf("set native stdout nonblocking: %w", err)
		return
	}
	defer syscall.SetNonblock(int(out.Fd()), false)
	for {
		var m NativeMessage
		select {
		case m = <-w.control:
		default:
			select {
			case m = <-w.control:
			case m = <-w.status:
			}
		}
		data, err := json.Marshal(m)
		if err != nil {
			w.failed <- fmt.Errorf("encode native %s: %w", m.Type, err)
			return
		}
		if len(data)+1 > MaxControlLine {
			w.failed <- errors.New("native JSON control exceeds 64 KiB")
			return
		}
		data = append(data, '\n')
		if err := writeDeadline(int(out.Fd()), data, 2*time.Second); err != nil {
			w.failed <- err
			return
		}
	}
}
func writeDeadline(fd int, data []byte, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for len(data) > 0 {
		n, err := syscall.Write(fd, data)
		if err == nil && n > 0 {
			data = data[n:]
			continue
		}
		if err == syscall.EINTR {
			continue
		}
		if err != syscall.EAGAIN && err != syscall.EWOULDBLOCK {
			return fmt.Errorf("write native control: %w", err)
		}
		if time.Now().After(deadline) {
			return errors.New("native control stdout stalled beyond 2s deadline")
		}
		time.Sleep(time.Millisecond)
	}
	return nil
}
