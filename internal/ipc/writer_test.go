package ipc

import (
	"os"
	"testing"
)

func TestWriterCloseWaitsForOutputGoroutine(t *testing.T) {
	readEnd, writeEnd, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = readEnd.Close() })
	writer := NewWriter(writeEnd, 1)
	writer.Close()
	if err := writer.SendControl(NativeMessage{Type: "heartbeat"}); err != ErrWriterClosed {
		t.Fatalf("SendControl after Close() = %v, want %v", err, ErrWriterClosed)
	}
	if err := writeEnd.Close(); err != nil {
		t.Fatal(err)
	}
}
