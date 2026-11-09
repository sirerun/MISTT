package service

import (
	"errors"
	"fmt"
	"math"

	"github.com/sirerun/MISTT/internal/audio"
)

func (p *activePair) nativeSessionID() string {
	if p.nativeID != "" {
		return p.nativeID
	}
	return p.id
}
func (p *activePair) transmittedLedger(source audio.Source) *sourceLedger {
	if p.remoteLedgers != nil {
		return p.remoteLedgers[source]
	}
	return p.ledgers[source]
}

// queueRemoteFrame accepts an already validated native frame (or a sample-exact
// fragment of one). Remote sequencing is independent of the original callback
// sequence; native-global ledger advancement happens once before splitting.
func queueRemoteFrame(p *activePair, f audio.Frame) error {
	origin, hasOrigin := p.remoteOrigins[f.Source]
	if p.remoteOffsetNS > 0 && !hasOrigin {
		return errors.New("missing remote source origin")
	}
	if f.StartSample < origin.StartSample || f.CaptureOffsetNS < p.remoteOffsetNS {
		return errors.New("native frame precedes remote origin")
	}
	if p.remoteLedgers == nil {
		p.remoteLedgers = map[audio.Source]*sourceLedger{audio.Microphone: {}, audio.CallAudio: {}}
	}
	l := p.remoteLedgers[f.Source]
	if l == nil {
		return errors.New("unknown remote source")
	}
	if l.nextSequence == math.MaxUint64 {
		return errors.New("remote frame sequence overflows")
	}
	f.SessionID = mustUUID(p.id)
	f.Sequence = l.nextSequence + 1
	f.StartSample -= origin.StartSample
	f.CaptureOffsetNS -= p.remoteOffsetNS
	if f.StartSample != l.nextSample || uint64(len(f.Samples)) > math.MaxUint64-l.nextSample {
		return errors.New("remote sample ledger gap")
	}
	if l.frames > 0 && (f.StartSample-l.firstSample) > math.MaxUint64/audio.SampleNS {
		return errors.New("remote source clock overflows")
	}
	if l.frames > 0 && l.firstOffset > math.MaxUint64-(f.StartSample-l.firstSample)*audio.SampleNS {
		return errors.New("remote source clock overflows")
	}
	if l.frames > 0 && (f.CaptureOffsetNS < l.firstOffset || (f.StartSample-l.firstSample) > math.MaxUint64/audio.SampleNS || f.CaptureOffsetNS != l.firstOffset+(f.StartSample-l.firstSample)*audio.SampleNS) {
		return errors.New("remote source clock gap")
	}
	if err := p.remote.QueueFrame(f); err != nil {
		return fmt.Errorf("queue %s audio to DGX: %w", f.Source, err)
	}
	if l.frames == 0 {
		l.firstOffset = f.CaptureOffsetNS
		l.firstSample = f.StartSample
	}
	l.nextSequence = f.Sequence
	l.nextSample = f.StartSample + uint64(len(f.Samples))
	l.frames++
	l.samples += uint64(len(f.Samples))
	return nil
}
