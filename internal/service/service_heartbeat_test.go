package service

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"testing"
	"time"

	"github.com/sirerun/MISTT/internal/config"
	"github.com/sirerun/MISTT/internal/ipc"
)

type nativeMessageAt struct {
	message ipc.NativeMessage
	fields  map[string]json.RawMessage
	at      time.Time
}

type heartbeatRun struct {
	service     *Service
	inputRead   *os.File
	inputWrite  *os.File
	outputRead  *os.File
	outputWrite *os.File
	output      *ipc.Writer
	listener    net.Listener
	messages    chan nativeMessageAt
	readDone    chan error
	runDone     chan struct{}
	runErr      error
}

func startHeartbeatRun(t *testing.T) *heartbeatRun {
	t.Helper()
	inputRead, inputWrite, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	outputRead, outputWrite, err := os.Pipe()
	if err != nil {
		_ = inputRead.Close()
		_ = inputWrite.Close()
		t.Fatal(err)
	}
	output := ipc.NewWriter(outputWrite, 8)
	service := New(config.Defaults(), nil, inputRead, output)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		output.Close()
		_ = inputRead.Close()
		_ = inputWrite.Close()
		_ = outputRead.Close()
		_ = outputWrite.Close()
		t.Fatal(err)
	}
	h := &heartbeatRun{
		service:     service,
		inputRead:   inputRead,
		inputWrite:  inputWrite,
		outputRead:  outputRead,
		outputWrite: outputWrite,
		output:      output,
		listener:    listener,
		messages:    make(chan nativeMessageAt, 32),
		readDone:    make(chan error, 1),
		runDone:     make(chan struct{}),
	}
	go func() {
		decoder := json.NewDecoder(outputRead)
		for {
			var raw json.RawMessage
			if err := decoder.Decode(&raw); err != nil {
				h.readDone <- err
				return
			}
			var message ipc.NativeMessage
			if err := json.Unmarshal(raw, &message); err != nil {
				h.readDone <- err
				return
			}
			var fields map[string]json.RawMessage
			if err := json.Unmarshal(raw, &fields); err != nil {
				h.readDone <- err
				return
			}
			h.messages <- nativeMessageAt{message: message, fields: fields, at: time.Now()}
		}
	}()
	go func() {
		h.runErr = service.Run(context.Background(), listener)
		close(h.runDone)
	}()
	t.Cleanup(func() {
		service.Shutdown()
		_ = inputWrite.Close()
		select {
		case <-h.runDone:
		case <-time.After(3 * time.Second):
			t.Error("service Run did not stop during cleanup")
		}
		output.Close()
		_ = outputWrite.Close()
		_ = inputRead.Close()
		_ = outputRead.Close()
		_ = listener.Close()
	})
	return h
}

func waitForHeartbeat(t *testing.T, h *heartbeatRun, timeout time.Duration) nativeMessageAt {
	t.Helper()
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	for {
		select {
		case got := <-h.messages:
			if got.message.Type == "heartbeat" {
				return got
			}
		case err := <-h.readDone:
			t.Fatalf("native output closed before heartbeat: %v", err)
		case <-deadline.C:
			t.Fatal("timed out waiting for native heartbeat")
		}
	}
}

func TestRunEmitsAdvancingHeartbeatsWhileMutedAndIdle(t *testing.T) {
	h := startHeartbeatRun(t)
	started := time.Now()
	var previous uint64
	var last time.Time
	for i := 0; i < 6; i++ {
		got := waitForHeartbeat(t, h, 4*time.Second)
		if len(got.fields) != 2 {
			t.Fatalf("heartbeat JSON has %d fields, want exactly type and counter", len(got.fields))
		}
		if got.message.Counter != previous+1 {
			t.Fatalf("heartbeat counter = %d after %d, want exact next counter", got.message.Counter, previous)
		}
		previous = got.message.Counter
		last = got.at
	}
	if elapsed := last.Sub(started); elapsed <= 2*time.Second {
		t.Fatalf("received six idle heartbeats in %v; expected service to remain healthy beyond the 2s watchdog", elapsed)
	}

	if err := h.inputWrite.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-h.runDone:
		if h.runErr != nil {
			t.Fatalf("Run after clean idle input closure = %v, want nil", h.runErr)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Run did not finish after idle input closure")
	}
	if err := h.outputWrite.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-h.readDone:
		if !errors.Is(err, io.EOF) {
			t.Fatalf("native output reader ended with %v, want EOF", err)
		}
	case <-time.After(time.Second):
		t.Fatal("native output did not close after Run returned")
	}
	if err := h.output.SendControl(ipc.NativeMessage{Type: "heartbeat", Counter: previous + 1}); !errors.Is(err, ipc.ErrWriterClosed) {
		t.Fatalf("heartbeat writer after Run teardown = %v, want ErrWriterClosed", err)
	}
}

func TestRunFailsClosedWhenHeartbeatOutputCloses(t *testing.T) {
	h := startHeartbeatRun(t)
	_ = waitForHeartbeat(t, h, 2*time.Second)
	h.output.Close()
	select {
	case <-h.runDone:
		if !errors.Is(h.runErr, ErrNativeDisconnected) {
			t.Fatalf("Run after heartbeat writer closure = %v, want ErrNativeDisconnected", h.runErr)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("Run did not fail closed after heartbeat writer closure")
	}
	h.service.mu.Lock()
	closureConfirmed := h.service.closureConfirmed
	h.service.mu.Unlock()
	if closureConfirmed {
		t.Fatal("service reported confirmed native closure after heartbeat output failure")
	}
}
