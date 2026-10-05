package ipc

import (
	"os"
	"testing"
)

func TestWriterCloseWaitsForOutputGoroutine(t *testing.T) {
	_, writeEnd, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	writer := NewWriter(writeEnd, 1)
	writer.Close()
	if err := writeEnd.Close(); err != nil {
		t.Fatal(err)
	}
}
