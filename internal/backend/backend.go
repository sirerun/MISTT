package backend

import (
	"context"

	"github.com/sirerun/MISTT/internal/audio"
)

type SourceFormat struct {
	Source       audio.Source `json:"source"`
	SampleRateHz uint32       `json:"sample_rate_hz"`
	Channels     uint32       `json:"channels"`
	Encoding     string       `json:"encoding"`
}
type StartRequest struct {
	SessionID string
	Language  string
}
type Ready struct {
	SourceSampleCaps                 map[audio.Source]uint64
	SessionID, Model, Language       string
	Sources                          []SourceFormat
	MaxActivePairs                   uint32
	StartupTimeoutMS, DrainTimeoutMS uint32
}
type Transcript struct {
	Source                                             audio.Source
	SourceEventSequence                                uint64
	SegmentID, Text                                    string
	Final                                              bool
	Confidence                                         float64
	StartSample, EndSample, StartOffsetNS, EndOffsetNS uint64
}
type CaptureStarted struct {
	RequestID          string
	CaptureEpochHostNS uint64
	CaptureEpochUnixMS int64
	Sources            []SourceFormat
	MicrophoneReady    bool
	CallAudioReady     bool
}
type Event struct {
	Transcript *Transcript
	SourceDone *SourceCompletion
	Done       bool
	Err        error
}
type SourceCompletion struct {
	Source       audio.Source
	Success      bool
	Code, Detail string
}
type EndRequest struct{ LastSequence, TotalSamples, CutoffOffsetNS uint64 }

type Session interface {
	Ready() Ready
	CaptureStarted(CaptureStarted) error
	QueueFrame(audio.Frame) error
	EndSource(audio.Source, EndRequest) error
	Events() <-chan Event
	Close() error
}
type Provider interface {
	Connect(context.Context, StartRequest) (Session, error)
}
