package service

import (
	"errors"
	"math"
	"sync"
	"time"

	"github.com/sirerun/MISTT/internal/audio"
)

// rolloverBuffer owns copied PCM only during a planned remote-generation handoff.
// Native sequence/sample/clock provenance is checked before any remapping. It is
// deliberately independent of native capture controls: mute/failure must cancel
// this buffer and stop capture, never replay retained audio into another session.
type rolloverBuffer struct {
	mu       sync.Mutex
	native   [16]byte
	boundary uint64
	deadline time.Time
	samples  map[audio.Source]uint64
	next     map[audio.Source]audio.Frame
	expected map[audio.Source]rolloverCursor
	frames   []audio.Frame
	closed   bool
}

const rolloverSamplesPerSource = uint64(8 * audio.SampleRate)
const rolloverDeadline = 10 * time.Second

type rolloverCursor struct{ Sequence, StartSample, CaptureOffsetNS uint64 }

// The cut planner must supply the exact next sample for BOTH sources from the
// validated native ledger. No first-frame gap may be hidden by rebasing.
func newRolloverBuffer(native [16]byte, boundary uint64, cursors map[audio.Source]rolloverCursor, now time.Time) (*rolloverBuffer, error) {
	if native == ([16]byte{}) || len(cursors) != 2 {
		return nil, errors.New("rollover requires paired native cursors")
	}
	expected := make(map[audio.Source]rolloverCursor, 2)
	for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		c, ok := cursors[source]
		if !ok || c.Sequence == 0 || c.CaptureOffsetNS < boundary || c.CaptureOffsetNS-boundary >= audio.SampleNS {
			return nil, errors.New("rollover cursor does not cover cut boundary")
		}
		expected[source] = c
	}
	return &rolloverBuffer{native: native, boundary: boundary, deadline: now.Add(rolloverDeadline), samples: map[audio.Source]uint64{}, next: map[audio.Source]audio.Frame{}, expected: expected}, nil
}

// append accepts frames wholly at/after the exact cut. The caller must split a
// crossing frame first; silently rounding a cut would discard or repeat speech.
func (b *rolloverBuffer) append(f audio.Frame, now time.Time) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return errors.New("rollover buffer closed")
	}
	fail := func(message string) error { b.clearLocked(); return errors.New(message) }
	if !now.Before(b.deadline) {
		return fail("rollover handoff deadline exceeded")
	}
	if err := f.Validate(); err != nil {
		return fail("invalid rollover PCM")
	}
	if f.SessionID != b.native || f.CaptureOffsetNS < b.boundary {
		return fail("rollover native provenance mismatch")
	}
	if _, ok := b.next[f.Source]; !ok {
		c := b.expected[f.Source]
		if f.Sequence != c.Sequence || f.StartSample != c.StartSample || f.CaptureOffsetNS != c.CaptureOffsetNS {
			return fail("rollover first frame does not match cut cursor")
		}
	}
	if previous, ok := b.next[f.Source]; ok {
		if previous.Sequence == math.MaxUint64 || f.Sequence != previous.Sequence+1 || f.StartSample != previous.StartSample+uint64(len(previous.Samples)) || f.CaptureOffsetNS != previous.CaptureOffsetNS+uint64(len(previous.Samples))*audio.SampleNS {
			return fail("rollover native ledger gap")
		}
	}
	count := uint64(len(f.Samples))
	if f.StartSample > math.MaxUint64-count || f.CaptureOffsetNS > math.MaxUint64-count*audio.SampleNS {
		return fail("rollover native ledger overflow")
	}
	if count > rolloverSamplesPerSource-b.samples[f.Source] {
		return fail("rollover PCM capacity exceeded")
	}
	f.Samples = append([]int16(nil), f.Samples...)
	b.frames = append(b.frames, f)
	b.next[f.Source] = f
	b.samples[f.Source] += count
	return nil
}

// take transfers retained frames exactly once. Global native frames remain
// available alongside remote frames so a transcript projection can retain the
// original capture identity and sample origin instead of fabricating a restart.
func (b *rolloverBuffer) take(remote [16]byte, now time.Time) ([]audio.Frame, []audio.Frame, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.closed {
		return nil, nil, errors.New("rollover buffer closed")
	}
	if !now.Before(b.deadline) {
		b.clearLocked()
		return nil, nil, errors.New("rollover handoff deadline exceeded")
	}
	if remote == ([16]byte{}) || remote == b.native {
		b.clearLocked()
		return nil, nil, errors.New("rollover requires a fresh remote generation")
	}
	if b.samples[audio.Microphone] == 0 || b.samples[audio.CallAudio] == 0 {
		b.clearLocked()
		return nil, nil, errors.New("rollover requires both source ledgers")
	}
	original := b.frames
	mapped := make([]audio.Frame, len(original))
	origins := map[audio.Source]uint64{}
	sequences := map[audio.Source]uint64{}
	for i, f := range original {
		if sequences[f.Source] == 0 {
			origins[f.Source] = f.StartSample
		}
		sequences[f.Source]++
		f.SessionID = remote
		f.Sequence = sequences[f.Source]
		f.StartSample -= origins[f.Source]
		f.CaptureOffsetNS -= b.boundary
		mapped[i] = f
	}
	b.frames = nil
	b.next = nil
	b.expected = nil
	b.samples = nil
	b.closed = true
	return original, mapped, nil
}
func (b *rolloverBuffer) cancel() { b.mu.Lock(); defer b.mu.Unlock(); b.clearLocked() }
func (b *rolloverBuffer) clearLocked() {
	for _, f := range b.frames {
		clear(f.Samples)
	}
	b.frames = nil
	b.next = nil
	b.expected = nil
	b.samples = nil
	b.closed = true
}

// splitRolloverFrame partitions without changing native identity, sample indices,
// or timestamps. The cut must lie on the 16 kHz sample grid.
func splitRolloverFrame(f audio.Frame, boundary uint64) (*audio.Frame, *audio.Frame, error) {
	if err := f.Validate(); err != nil {
		return nil, nil, err
	}
	if boundary <= f.CaptureOffsetNS {
		return nil, &f, nil
	}
	delta := boundary - f.CaptureOffsetNS
	if delta%audio.SampleNS != 0 {
		return nil, nil, errors.New("rollover boundary is not sample aligned")
	}
	count := delta / audio.SampleNS
	if count >= uint64(len(f.Samples)) {
		return &f, nil, nil
	}
	left, right := f, f
	left.Samples = f.Samples[:count]
	right.Samples = f.Samples[count:]
	right.StartSample += count
	right.CaptureOffsetNS = boundary
	// Native sequence identifies the original callback frame in both pieces. The
	// remote generation assigns its own independent sequence ledger.
	return &left, &right, nil
}
