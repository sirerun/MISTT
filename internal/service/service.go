package service

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"strings"
	"sync"
	"time"

	"github.com/sirerun/MISTT/gen/mistt/v1"
	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
	"github.com/sirerun/MISTT/internal/config"
	"github.com/sirerun/MISTT/internal/ipc"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

var ErrNativeDisconnected = errors.New("native owner disconnected")

type subscriber struct {
	id       uint64
	language string
	events   chan *misttv1.StreamResponse
	done     chan struct{}
	terminal chan error
	once     sync.Once
}
type sourceLedger struct {
	nextSequence uint64
	nextSample   uint64
	firstOffset  uint64
	firstSample  uint64
	frames       uint64
	samples      uint64
	ended        bool
}
type activePair struct {
	id             string
	remote         backend.Session
	ready          backend.Ready
	reqID          string
	epochHostNS    uint64
	epochUnixMS    int64
	started        *misttv1.StreamResponse
	sequence       uint64
	ledgers        map[audio.Source]*sourceLedger
	pending        [2][]audio.Frame
	sourceEnds     map[audio.Source]bool
	stopping       bool
	closed         bool
	cutoffHostNS   uint64
	cutoffKnown    bool
	cutoffOffsetNS uint64
	runtimeFailure error
	seen           map[string]segmentState
}
type segmentState struct {
	final bool
	text  string
}
type commandRecord struct {
	requestID, payload string
	result             ipc.NativeMessage
}
type muteRecord struct {
	payload  string
	result   *misttv1.Status
	code     codes.Code
	detail   string
	done     chan struct{}
	complete bool
}

type Service struct {
	misttv1.UnimplementedMisttServer
	cfg               config.Config
	backend           backend.Provider
	input             *ipc.Reader
	output            *ipc.Writer
	incoming          chan ipc.Event
	fatal             chan error
	changed           chan struct{}
	statusChanged     chan struct{}
	mu                sync.Mutex
	muted             bool
	capturing         bool
	reason            string
	revision          uint64
	closureConfirmed  bool
	updateReserved    bool
	clients           map[uint64]*subscriber
	nextClient        uint64
	active            *activePair
	starting          bool
	startCancel       context.CancelFunc
	stopping          bool
	shutdownRequested bool
	cleanNativeEOF    bool
	closed            chan struct{}
	shutdownDone      chan struct{}
	closeOnce         sync.Once
	heartbeat         uint64
	commandHigh       uint64
	commands          map[uint64]commandRecord
	requestCommands   map[string]uint64
	muteRequests      map[string]*muteRecord
	muteOrder         []string
	segmentFinal      map[string]segmentState
}

func New(cfg config.Config, provider backend.Provider, in io.Reader, out *ipc.Writer) *Service {
	s := &Service{cfg: cfg, backend: provider, input: ipc.NewReader(in), output: out, incoming: make(chan ipc.Event, 256), fatal: make(chan error, 1), changed: make(chan struct{}, 1), statusChanged: make(chan struct{}), muted: true, reason: "startup_muted", revision: 1, closureConfirmed: true, clients: map[uint64]*subscriber{}, closed: make(chan struct{}), shutdownDone: make(chan struct{}), commands: map[uint64]commandRecord{}, requestCommands: map[string]uint64{}, muteRequests: map[string]*muteRecord{}, segmentFinal: map[string]segmentState{}}
	return s
}

// Run owns the only native IPC generation and loopback RPC state machine.
func (s *Service) Run(ctx context.Context, listener net.Listener) error {
	if listener == nil {
		return errors.New("loopback gRPC listener is required")
	}
	grpcServer := grpc.NewServer()
	misttv1.RegisterMisttServer(grpcServer, s)
	s.mu.Lock()
	s.output.SendStatus(s.nativeStatusLocked())
	s.mu.Unlock()
	go s.readNative()
	go s.supervise()
	go func() {
		select {
		case e := <-s.output.Failed():
			s.failProcess(e)
		case <-ctx.Done():
			s.requestShutdown()
		case <-s.closed:
		}
	}()
	serveErr := make(chan error, 1)
	go func() { serveErr <- grpcServer.Serve(listener) }()
	select {
	case err := <-serveErr:
		s.requestShutdown()
		<-s.shutdownDone
		return err
	case <-ctx.Done():
		s.requestShutdown()
		<-s.shutdownDone
		grpcServer.GracefulStop()
		return ctx.Err()
	case <-s.closed:
		s.mu.Lock()
		cleanEOF := s.cleanNativeEOF
		s.mu.Unlock()
		if cleanEOF {
			grpcServer.Stop()
			return nil
		}
		grpcServer.Stop()
		return ErrNativeDisconnected
	}
}
func (s *Service) Shutdown() { s.requestShutdown() }
func (s *Service) requestShutdown() {
	s.mu.Lock()
	if !s.shutdownRequested {
		s.shutdownRequested = true
		s.muted = true
		s.reason = "shutdown"
		s.publishLocked()
		s.signalLocked()
	}
	cancel := s.startCancel
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	s.terminateClients(status.Error(codes.Unavailable, "relay is shutting down"))
}
func (s *Service) shutdown() {
	s.closeOnce.Do(func() {
		close(s.closed)
		close(s.shutdownDone)
		s.mu.Lock()
		s.muted = true
		s.reason = "shutdown"
		s.publishLocked()
		s.signalLocked()
		s.mu.Unlock()
	})
}
func (s *Service) failProcess(err error) {
	select {
	case s.fatal <- err:
	default:
	}
	s.mu.Lock()
	pair := s.active
	s.active = nil
	s.capturing = false
	s.closureConfirmed = false
	s.muted = true
	s.reason = "native_failure"
	s.publishLocked()
	s.mu.Unlock()
	if pair != nil {
		_ = pair.remote.Close()
	}
	s.terminateClients(status.Error(codes.Unavailable, "native owner IPC failed"))
	s.shutdown()
}
func (s *Service) readNative() {
	var heartbeat uint64
	for {
		event, err := s.input.ReadEvent()
		if err != nil {
			if err == io.EOF {
				s.handleNativeEOF()
			} else {
				s.failProcess(fmt.Errorf("native IPC reader: %w", err))
			}
			return
		}
		if event.Control != nil {
			if event.Control.Type == "heartbeat" {
				if event.Control.Counter <= heartbeat {
					s.failProcess(errors.New("native heartbeat counter is stale"))
					return
				}
				heartbeat = event.Control.Counter
				continue
			}
			if strings.HasPrefix(event.Control.Type, "native_") {
				if err := s.applyNativeCommand(*event.Control); err != nil {
					s.failProcess(err)
					return
				}
				continue
			}
		}
		select {
		case s.incoming <- event:
		default:
			s.failProcess(errors.New("bounded native reader queue is full"))
			return
		}
	}
}
func (s *Service) handleNativeEOF() {
	s.mu.Lock()
	safe := s.muted && s.active == nil && !s.starting && !s.stopping && !s.capturing && s.closureConfirmed
	if safe {
		s.cleanNativeEOF = true
		s.shutdownRequested = true
		s.muted = true
		s.reason = "shutdown"
		s.publishLocked()
		s.signalLocked()
	}
	s.mu.Unlock()
	if safe {
		s.terminateClients(status.Error(codes.Unavailable, "native owner closed its IPC after confirmed idle"))
		return
	}
	s.failProcess(ErrNativeDisconnected)
}
func (s *Service) signalLocked() {
	select {
	case s.changed <- struct{}{}:
	default:
	}
}
func (s *Service) signal() { s.mu.Lock(); s.signalLocked(); s.mu.Unlock() }
func (s *Service) publishLocked() {
	s.revision++
	if s.revision == 0 {
		s.revision = 1
	}
	close(s.statusChanged)
	s.statusChanged = make(chan struct{})
	s.output.SendStatus(s.nativeStatusLocked())
}
func (s *Service) statusLocked() *misttv1.Status {
	return &misttv1.Status{Muted: s.muted, ConnectedClients: uint32(len(s.clients)), Capturing: s.capturing, Reason: s.reason, Revision: s.revision, UpdateReady: s.updateReadyLocked(), UpdateReserved: s.updateReserved}
}
func (s *Service) nativeStatusLocked() ipc.NativeMessage {
	return ipc.NativeMessage{Type: "status", Muted: s.muted, Capturing: s.capturing, ConnectedClients: uint32(len(s.clients)), Reason: s.reason, Revision: s.revision, UpdateReady: s.updateReadyLocked(), UpdateReserved: s.updateReserved}
}
func (s *Service) updateReadyLocked() bool {
	return s.muted && s.active == nil && !s.starting && !s.capturing && s.closureConfirmed
}
func (s *Service) demandLocked() bool {
	return !s.muted && !s.updateReserved && !s.shutdownRequested && len(s.clients) > 0
}
func (s *Service) canStartLocked() bool {
	return s.demandLocked() && s.closureConfirmed && !s.starting && s.active == nil
}
func (s *Service) supervise() {
	for {
		select {
		case <-s.closed:
			return
		default:
		}
		s.mu.Lock()
		demand := s.demandLocked()
		canStart := s.canStartLocked()
		active := s.active
		stopping := s.stopping
		shutdownRequested := s.shutdownRequested
		reason := s.reason
		s.mu.Unlock()
		if active != nil {
			if !stopping {
				if demand {
					s.runPair(active)
				} else {
					s.stopPair(active, reason, nil)
				}
			}
			continue
		}
		if canStart {
			if err := s.startPair(); err != nil {
				s.mu.Lock()
				s.muted = true
				s.capturing = false
				// A remote readiness failure before native capture leaves the
				// previous confirmed-idle state intact. startPair marks closure
				// unconfirmed only when its correlated cleanup failed.
				s.reason = "backend_failure"
				s.publishLocked()
				s.signalLocked()
				s.mu.Unlock()
			}
			continue
		}
		if shutdownRequested {
			s.shutdown()
			return
		}
		select {
		case <-s.changed:
		case <-s.closed:
			return
		case err := <-s.fatal:
			s.failProcess(err)
			return
		}
	}
}
func (s *Service) startPair() error {
	s.mu.Lock()
	if !s.demandLocked() || !s.closureConfirmed || s.starting || s.active != nil {
		s.mu.Unlock()
		return nil
	}
	s.starting = true
	s.publishLocked()
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		if s.starting {
			s.starting = false
			s.publishLocked()
		}
		s.signalLocked()
		s.mu.Unlock()
	}()
	ctx, cancel := context.WithTimeout(context.Background(), s.cfg.StartupTimeout)
	defer cancel()
	s.mu.Lock()
	s.startCancel = cancel
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.startCancel = nil; s.mu.Unlock() }()
	id, err := newUUID()
	if err != nil {
		return err
	}
	remote, err := s.backend.Connect(ctx, backend.StartRequest{SessionID: id, Language: s.cfg.Language})
	if err != nil {
		return fmt.Errorf("paired remote readiness failed: %w", err)
	}
	if err := ctx.Err(); err != nil {
		_ = remote.Close()
		return fmt.Errorf("paired start canceled before native capture: %w", err)
	}
	ready := remote.Ready()
	if ready.SessionID != id || ready.Language != s.cfg.Language || ready.Model == "" {
		_ = remote.Close()
		return errors.New("remote provider returned an invalid paired session")
	}
	reqID, err := newUUID()
	if err != nil {
		_ = remote.Close()
		return err
	}
	formats := []ipc.SourceFormat{{Source: audio.Microphone, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}, {Source: audio.CallAudio, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}}
	start := ipc.NativeMessage{Type: "capture_start", RequestID: reqID, SessionID: id, Sources: formats, Device: s.cfg.MicrophoneDevice, BundleID: s.cfg.TargetBundleID, IncludeHelpers: s.cfg.IncludeHelperPIDs, IncludeHelperExecutables: s.cfg.IncludeHelperExecutables}
	if err := s.output.SendControl(start); err != nil {
		_ = remote.Close()
		return fmt.Errorf("queue native paired start: %w", err)
	}
	failStartedRequest := func(cause error) error {
		closed := s.stopUnstarted(id)
		s.mu.Lock()
		s.closureConfirmed = closed
		s.capturing = false
		s.mu.Unlock()
		_ = remote.Close()
		return cause
	}
	deadline := time.NewTimer(s.cfg.StartupTimeout)
	defer deadline.Stop()
	for {
		select {
		case <-s.closed:
			return failStartedRequest(ErrNativeDisconnected)
		case <-ctx.Done():
			return failStartedRequest(ctx.Err())
		case <-deadline.C:
			return failStartedRequest(context.DeadlineExceeded)
		case event := <-s.incoming:
			if event.Frame != nil {
				return failStartedRequest(errors.New("native sent audio before capture_started"))
			}
			m := event.Control
			if m == nil {
				continue
			}
			switch m.Type {
			case "capture_started":
				if m.RequestID != reqID || m.SessionID != id {
					continue
				}
				if m.CaptureEpochUnixMS < 0 {
					return failStartedRequest(errors.New("native capture epoch wall clock is negative"))
				}
				if err := remote.CaptureStarted(backend.CaptureStarted{RequestID: m.RequestID, CaptureEpochHostNS: m.CaptureEpochHostNS, CaptureEpochUnixMS: m.CaptureEpochUnixMS, Sources: formatsToBackend(formats), MicrophoneReady: m.MicrophoneReady, CallAudioReady: m.CallAudioReady}); err != nil {
					return failStartedRequest(fmt.Errorf("forward capture epoch to DGX: %w", err))
				}
				pair := &activePair{id: id, remote: remote, ready: ready, reqID: reqID, epochHostNS: m.CaptureEpochHostNS, epochUnixMS: m.CaptureEpochUnixMS, sequence: 1, ledgers: map[audio.Source]*sourceLedger{audio.Microphone: {}, audio.CallAudio: {}}, sourceEnds: map[audio.Source]bool{}, seen: map[string]segmentState{}}
				pair.started = &misttv1.StreamResponse{SessionId: id, Sequence: 1, Payload: &misttv1.StreamResponse_SessionStarted{SessionStarted: &misttv1.SessionStarted{Backend: "dgx_paired", Model: ready.Model, Language: ready.Language, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding, CaptureEpochHostNs: m.CaptureEpochHostNS, CaptureEpochUnixMs: m.CaptureEpochUnixMS, Sources: []*misttv1.SourceFormat{{Source: string(audio.Microphone), SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}, {Source: string(audio.CallAudio), SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}}}}}
				s.mu.Lock()
				s.active = pair
				s.starting = false
				s.capturing = true
				s.closureConfirmed = false
				s.reason = "capturing"
				s.publishLocked()
				s.broadcastLocked(pair.started)
				s.signalLocked()
				s.mu.Unlock()
				return nil
			case "capture_failed":
				if m.SessionID == id {
					failure := fmt.Errorf("native paired start failed (%s)", m.Code)
					if m.ClosureConfirmed {
						s.mu.Lock()
						s.closureConfirmed = true
						s.capturing = false
						s.mu.Unlock()
						_ = remote.Close()
						return failure
					}
					return failStartedRequest(failure)
				}
			case "status": // Reserved for a forward-compatible native child status update.
			default:
				return failStartedRequest(fmt.Errorf("unexpected native %s while starting paired capture", m.Type))
			}
		case err := <-s.fatal:
			return failStartedRequest(err)
		}
	}
}
func (s *Service) stopUnstarted(sessionID string) bool {
	requestID, err := newUUID()
	if err != nil {
		return false
	}
	if err := s.output.SendControl(ipc.NativeMessage{Type: "capture_stop", RequestID: requestID, SessionID: sessionID, Reason: "native_failure"}); err != nil {
		return false
	}
	timer := time.NewTimer(s.cfg.StartupTimeout)
	defer timer.Stop()
	for {
		select {
		case <-timer.C:
			return false
		case event := <-s.incoming:
			if event.Frame != nil {
				continue
			}
			if m := event.Control; m != nil && m.Type == "capture_stopped" && m.RequestID == requestID && m.SessionID == sessionID {
				return m.Validate() == nil
			}
		case <-s.closed:
			return false
		case <-s.fatal:
			return false
		}
	}
}
func formatsToBackend(v []ipc.SourceFormat) []backend.SourceFormat {
	out := make([]backend.SourceFormat, len(v))
	for i, f := range v {
		out[i] = backend.SourceFormat{Source: f.Source, SampleRateHz: f.SampleRateHz, Channels: f.Channels, Encoding: f.Encoding}
	}
	return out
}
func (s *Service) runPair(pair *activePair) {
	maxTimer := time.NewTimer(s.cfg.MaxDuration)
	var max <-chan time.Time
	if s.cfg.MaxDuration > 0 {
		max = maxTimer.C
	}
	defer maxTimer.Stop()
	remoteEvents := pair.remote.Events()
	for {
		select {
		case <-s.closed:
			s.stopPair(pair, "shutdown", nil)
			return
		case <-max:
			s.mu.Lock()
			s.muted = true
			s.reason = "max_duration"
			s.publishLocked()
			s.signalLocked()
			s.mu.Unlock()
			s.stopPair(pair, "max_duration", nil)
			return
		case <-s.changed:
			s.mu.Lock()
			demand := s.demandLocked()
			reason := s.reason
			s.mu.Unlock()
			if !demand {
				s.stopPair(pair, reason, nil)
				return
			}
		case event := <-s.incoming:
			if err := s.activeEvent(pair, event, nil); err != nil {
				s.stopPair(pair, "native_failure", err)
				return
			}
		case e, ok := <-remoteEvents:
			if !ok {
				s.stopPair(pair, "backend_failure", errors.New("DGX event stream ended before EOF"))
				return
			}
			if e.Err != nil {
				s.stopPair(pair, "backend_failure", e.Err)
				return
			}
			if e.Transcript != nil {
				if err := s.publishTranscript(pair, e.Transcript); err != nil {
					s.stopPair(pair, "backend_failure", err)
					return
				}
			} else if e.SourceDone != nil || e.Done {
				s.stopPair(pair, "backend_failure", errors.New("DGX completed before paired native EOF"))
				return
			}
		case err := <-s.fatal:
			s.stopPair(pair, "native_failure", err)
			return
		}
	}
}
func (s *Service) activeEvent(pair *activePair, event ipc.Event, cutoff *uint64) error {
	if event.Frame != nil {
		return s.acceptFrame(pair, *event.Frame, cutoff)
	}
	m := event.Control
	if m == nil {
		return errors.New("empty native event")
	}
	switch m.Type {
	case "status":
		return nil
	case "capture_failed":
		if m.SessionID != pair.id {
			return nil
		}
		return fmt.Errorf("native paired capture failed (%s)", m.Code)
	case "capture_stopped":
		return errors.New("unsolicited capture_stopped outside stop handshake")
	case "source_end":
		if m.SessionID != pair.id {
			return nil
		}
		if !pair.stopping || !pair.cutoffKnown {
			return errors.New("native source_end arrived before acknowledged paired cutoff")
		}
		return s.acceptSourceEnd(pair, *m)
	default:
		return fmt.Errorf("unexpected native %s during paired capture", m.Type)
	}
}
func (s *Service) acceptFrame(pair *activePair, f audio.Frame, cutoff *uint64) error {
	if f.SessionID != mustUUID(pair.id) {
		return errors.New("native audio generation does not match paired session")
	}
	l := pair.ledgers[f.Source]
	if l == nil || l.ended {
		return errors.New("native audio arrived for unknown or ended source")
	}
	if l.nextSequence == math.MaxUint64 || f.Sequence != l.nextSequence+1 || f.StartSample != l.nextSample {
		return fmt.Errorf("native %s sequence or sample ledger has a gap", f.Source)
	}
	if l.nextSequence == math.MaxUint64 || l.nextSample > math.MaxUint64-uint64(len(f.Samples)) || f.Sequence > math.MaxUint64-l.frames || uint64(len(f.Samples)) > math.MaxUint64-l.samples {
		return errors.New("native source sample ledger overflow")
	}
	if l.frames == 0 {
		l.firstOffset = f.CaptureOffsetNS
		l.firstSample = f.StartSample
	} else {
		expected := f.CaptureOffsetNS
		if f.StartSample >= l.firstSample {
			delta := f.StartSample - l.firstSample
			if delta > math.MaxUint64/audio.SampleNS {
				return errors.New("native sample offset overflows")
			}
			mapped := l.firstOffset + delta*audio.SampleNS
			if mapped < l.firstOffset || mapped != expected {
				return errors.New("native sample index and capture offset disagree")
			}
		}
	}
	if pair.epochHostNS > math.MaxUint64-f.CaptureOffsetNS {
		return errors.New("native host timestamp overflows")
	}
	firstHost := pair.epochHostNS + f.CaptureOffsetNS
	if cutoff != nil {
		for i := range f.Samples {
			delta := uint64(i) * audio.SampleNS
			if firstHost > math.MaxUint64-delta || firstHost+delta >= *cutoff {
				return errors.New("native retained sample is at or beyond acknowledged cutoff")
			}
		}
	}
	if err := pair.remote.QueueFrame(f); err != nil {
		return fmt.Errorf("queue %s audio to DGX: %w", f.Source, err)
	}
	l.nextSequence = f.Sequence
	l.nextSample = f.StartSample + uint64(len(f.Samples))
	l.frames++
	l.samples += uint64(len(f.Samples))
	return nil
}
func (s *Service) acceptSourceEnd(pair *activePair, m ipc.NativeMessage) error {
	if !m.Source.Valid() {
		return errors.New("native source_end source is invalid")
	}
	l := pair.ledgers[m.Source]
	if l == nil || l.ended || pair.sourceEnds[m.Source] {
		return errors.New("duplicate or unknown native source_end")
	}
	if m.LastSequence != l.nextSequence || m.TotalSamples != l.nextSample {
		return fmt.Errorf("native %s source_end totals do not match transmitted sample ledger", m.Source)
	}
	if err := pair.remote.EndSource(m.Source, backend.EndRequest{LastSequence: m.LastSequence, TotalSamples: m.TotalSamples, CutoffOffsetNS: pair.cutoffOffsetNS}); err != nil {
		return err
	}
	l.ended = true
	pair.sourceEnds[m.Source] = true
	return nil
}
func (s *Service) stopPair(pair *activePair, reason string, cause error) {
	s.mu.Lock()
	if s.active != pair || pair.stopping {
		s.mu.Unlock()
		return
	}
	pair.stopping = true
	s.stopping = true
	if reason == "" {
		reason = "muted"
	}
	s.capturing = true
	if cause != nil {
		s.reason = "native_failure"
	}
	s.publishLocked()
	s.mu.Unlock()
	stopWindow := s.cfg.DrainTimeout
	if stopWindow <= 0 {
		stopWindow = 5 * time.Second
	}
	if pair.ready.DrainTimeoutMS > 0 {
		remoteWindow := time.Duration(pair.ready.DrainTimeoutMS) * time.Millisecond
		if remoteWindow < stopWindow {
			stopWindow = remoteWindow
		}
	}
	stopDeadline := time.Now().Add(stopWindow)
	reqID, err := newUUID()
	if err != nil {
		err = fmt.Errorf("create stop request ID: %w", err)
		s.abortPair(pair, "native_failure", err)
		return
	}
	if err = s.output.SendControl(ipc.NativeMessage{Type: "capture_stop", RequestID: reqID, SessionID: pair.id, Reason: normalizeStopReason(reason)}); err != nil {
		s.abortPair(pair, "native_failure", err)
		return
	}
	ack, buffered, runtimeFailure, ackErr := s.waitForStopAck(pair, reqID, cause, stopDeadline)
	if ackErr != nil {
		s.abortPair(pair, stopFailureReason(ackErr), ackErr)
		return
	}
	pair.closed = true
	pair.cutoffHostNS = ack.CutoffHostNS
	pair.cutoffKnown = true
	if pair.cutoffHostNS < pair.epochHostNS {
		s.abortPair(pair, "native_failure", errors.New("native cutoff precedes shared capture epoch"))
		return
	}
	pair.cutoffOffsetNS = pair.cutoffHostNS - pair.epochHostNS
	s.mu.Lock()
	s.capturing = false
	s.closureConfirmed = true
	if cause != nil {
		s.reason = "native_failure"
	} else {
		s.reason = normalizeStopReason(reason)
	}
	s.publishLocked()
	s.mu.Unlock()
	for _, f := range buffered {
		if err := s.acceptFrame(pair, f, &pair.cutoffHostNS); err != nil {
			s.abortPair(pair, "native_failure", err)
			return
		}
	}
	if err := s.collectSourceEnds(pair, stopDeadline); err != nil {
		s.abortPair(pair, stopFailureReason(err), err)
		return
	}
	remaining := time.Until(stopDeadline)
	if remaining <= 0 {
		s.abortPair(pair, "drain_timeout", context.DeadlineExceeded)
		return
	}
	timer := time.NewTimer(remaining)
	defer timer.Stop()
	remoteEvents := pair.remote.Events()
	done := false
	failure := error(nil)
	for !done {
		select {
		case <-timer.C:
			failure = context.DeadlineExceeded
			done = true
		case e, ok := <-remoteEvents:
			if !ok {
				failure = errors.New("DGX closed before paired done")
				done = true
				continue
			}
			if e.Err != nil {
				failure = e.Err
				done = true
				continue
			}
			if e.Transcript != nil {
				if err := s.publishTranscript(pair, e.Transcript); err != nil {
					failure = err
					done = true
				}
			} else if e.SourceDone != nil {
				if !e.SourceDone.Success {
					failure = fmt.Errorf("DGX %s context failed (%s)", e.SourceDone.Source, e.SourceDone.Code)
					done = true
				}
			} else if e.Done {
				done = true
			}
		case event := <-s.incoming:
			if event.Frame != nil {
				failure = errors.New("audio arrived after both native EOF barriers")
				done = true
			} else if m := event.Control; m != nil && (m.Type == "capture_failed" || m.Type == "status") {
				if m.Type == "capture_failed" {
					failure = errors.New("native reported failure during paired drain")
					done = true
				}
			}
		case <-s.closed:
			failure = ErrNativeDisconnected
			done = true
		}
	}
	if failure == nil && runtimeFailure != nil {
		failure = runtimeFailure
	}
	if failure != nil {
		_ = pair.remote.Close()
		finishReason := "native_failure"
		if errors.Is(failure, context.DeadlineExceeded) {
			finishReason = "drain_timeout"
		}
		s.mu.Lock()
		s.muted = true
		s.reason = finishReason
		s.publishLocked()
		s.signalLocked()
		s.mu.Unlock()
		s.finishPair(pair, finishReason, failure)
	} else {
		_ = pair.remote.Close()
		s.finishPair(pair, normalizeStopReason(reason), nil)
	}
}
func (s *Service) waitForStopAck(pair *activePair, reqID string, cause error, deadline time.Time) (ipc.NativeMessage, []audio.Frame, error, error) {
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return ipc.NativeMessage{}, nil, cause, context.DeadlineExceeded
	}
	t := time.NewTimer(remaining)
	defer t.Stop()
	var buffered []audio.Frame
	limit := s.cfg.FrameQueue * 2
	for {
		select {
		case <-t.C:
			return ipc.NativeMessage{}, nil, cause, context.DeadlineExceeded
		case <-s.closed:
			return ipc.NativeMessage{}, nil, cause, ErrNativeDisconnected
		case event := <-s.incoming:
			if event.Frame != nil {
				if len(buffered) >= limit {
					return ipc.NativeMessage{}, nil, cause, errors.New("native post-cutoff holding queue is full")
				}
				buffered = append(buffered, *event.Frame)
				continue
			}
			m := event.Control
			if m == nil {
				continue
			}
			if m.Type == "capture_failed" && m.SessionID == pair.id {
				if cause == nil {
					cause = fmt.Errorf("native paired failure (%s)", m.Code)
				}
				continue
			}
			if m.Type == "capture_stopped" {
				if m.SessionID != pair.id || m.RequestID != reqID {
					continue
				}
				if err := m.Validate(); err != nil {
					return ipc.NativeMessage{}, nil, cause, err
				}
				return *m, buffered, cause, nil
			}
			if m.Type == "status" {
				continue
			}
			return ipc.NativeMessage{}, nil, cause, fmt.Errorf("unexpected native %s while awaiting paired stop ACK", m.Type)
		case err := <-s.fatal:
			return ipc.NativeMessage{}, nil, cause, err
		}
	}
}
func (s *Service) collectSourceEnds(pair *activePair, deadline time.Time) error {
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return context.DeadlineExceeded
	}
	timer := time.NewTimer(remaining)
	defer timer.Stop()
	for !pair.sourceEnds[audio.Microphone] || !pair.sourceEnds[audio.CallAudio] {
		select {
		case <-timer.C:
			return context.DeadlineExceeded
		case <-s.closed:
			return ErrNativeDisconnected
		case event := <-s.incoming:
			if event.Frame != nil {
				if err := s.acceptFrame(pair, *event.Frame, &pair.cutoffHostNS); err != nil {
					return err
				}
				continue
			}
			if m := event.Control; m != nil {
				switch m.Type {
				case "source_end":
					if err := s.acceptSourceEnd(pair, *m); err != nil {
						return err
					}
				case "capture_failed":
					return errors.New("native failed after closure ACK")
				case "status":
				default:
					return fmt.Errorf("unexpected native %s after closure ACK", m.Type)
				}
			}
		case err := <-s.fatal:
			return err
		}
	}
	return nil
}
func stopFailureReason(err error) string {
	if errors.Is(err, context.DeadlineExceeded) {
		return "drain_timeout"
	}
	return "native_failure"
}
func (s *Service) abortPair(pair *activePair, reason string, err error) {
	_ = pair.remote.Close()
	s.mu.Lock()
	s.capturing = false
	s.closureConfirmed = pair.closed
	s.muted = true
	s.reason = reason
	s.publishLocked()
	s.mu.Unlock()
	s.terminateClients(status.Error(codes.Unavailable, sanitize(err)))
	s.finishPair(pair, reason, err)
}
func (s *Service) finishPair(pair *activePair, reason string, err error) {
	s.mu.Lock()
	if s.active == pair {
		pair.sequence++
		detail := ""
		code := int32(codes.OK)
		if err != nil {
			detail = sanitize(err)
			if errors.Is(err, context.DeadlineExceeded) {
				code = int32(codes.DeadlineExceeded)
			} else {
				code = int32(codes.Unavailable)
			}
		}
		event := &misttv1.StreamResponse{SessionId: pair.id, Sequence: pair.sequence, Payload: &misttv1.StreamResponse_SessionStopped{SessionStopped: &misttv1.SessionStopped{Reason: reason, GrpcCode: code, Detail: detail}}}
		s.broadcastLocked(event)
		s.active = nil
		s.stopping = false
		s.capturing = false
		if err == nil {
			s.closureConfirmed = true
		}
		s.publishLocked()
		s.signalLocked()
	}
	s.mu.Unlock()
}
func (s *Service) publishTranscript(pair *activePair, t *backend.Transcript) error {
	if t == nil || !t.Source.Valid() || t.SegmentID == "" || t.EndSample < t.StartSample || t.EndOffsetNS < t.StartOffsetNS {
		return errors.New("DGX transcript has invalid source or sample interval")
	}
	ledger := pair.ledgers[t.Source]
	if ledger == nil || t.StartSample > ledger.nextSample {
		return errors.New("DGX transcript starts beyond retained source samples")
	}
	if ledger.frames == 0 && (t.StartSample != 0 || t.EndSample != 0 || t.StartOffsetNS != 0 || t.EndOffsetNS != 0) {
		return errors.New("DGX transcript refers to an empty source timeline")
	}
	if ledger.frames > 0 && t.StartSample < ledger.firstSample {
		return errors.New("DGX transcript starts before retained sample timeline")
	}
	clippedSamples := false
	if t.EndSample > ledger.nextSample {
		t.EndSample = ledger.nextSample
		clippedSamples = true
	}
	if t.EndSample < t.StartSample {
		t.EndSample = t.StartSample
	}
	if ledger.frames > 0 && t.EndSample >= ledger.firstSample {
		delta := t.EndSample - ledger.firstSample
		if delta > math.MaxUint64/audio.SampleNS || ledger.firstOffset > math.MaxUint64-delta*audio.SampleNS {
			return errors.New("clipped transcript offset overflows")
		}
		clipped := ledger.firstOffset + delta*audio.SampleNS
		if clippedSamples {
			t.EndOffsetNS = clipped
		} else if t.EndOffsetNS != clipped {
			return errors.New("DGX transcript end sample and offset disagree")
		}
		if t.StartSample-ledger.firstSample > math.MaxUint64/audio.SampleNS {
			return errors.New("DGX transcript starts outside retained sample timeline")
		}
		startOffset := ledger.firstOffset + (t.StartSample-ledger.firstSample)*audio.SampleNS
		if startOffset < ledger.firstOffset || startOffset != t.StartOffsetNS {
			return errors.New("DGX transcript start sample and offset disagree")
		}
	}
	if t.EndOffsetNS < t.StartOffsetNS {
		return errors.New("clipped transcript interval is invalid")
	}
	key := string(t.Source) + "\x00" + t.SegmentID
	prior, ok := pair.seen[key]
	if ok && prior.final && (prior.text != t.Text || !t.Final) {
		return errors.New("DGX changed a finalized transcript segment")
	}
	if t.Final {
		pair.seen[key] = segmentState{final: true, text: t.Text}
	} else if !ok {
		pair.seen[key] = segmentState{text: t.Text}
	}
	if t.StartOffsetNS > math.MaxUint64-pair.epochHostNS {
		return errors.New("transcript host offset overflows")
	}
	if t.EndOffsetNS > math.MaxUint64-pair.epochHostNS {
		return errors.New("transcript end host offset overflows")
	}
	if t.StartOffsetNS/1e6 > math.MaxInt64-pair.epochUnixMS {
		return errors.New("transcript wall clock overflows")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.active != pair {
		return nil
	}
	pair.sequence++
	event := &misttv1.StreamResponse{SessionId: pair.id, Sequence: pair.sequence, Payload: &misttv1.StreamResponse_Transcription{Transcription: &misttv1.TranscriptionEvent{Source: string(t.Source), SourceEventSequence: t.SourceEventSequence, SegmentId: t.SegmentID, Text: t.Text, IsFinal: t.Final, Confidence: t.Confidence, StartSample: t.StartSample, EndSample: t.EndSample, StartOffsetNs: t.StartOffsetNS, EndOffsetNs: t.EndOffsetNS, WallClockUnixMs: pair.epochUnixMS + int64(t.StartOffsetNS/1e6)}}}
	s.broadcastLocked(event)
	return nil
}
func (s *Service) broadcastLocked(event *misttv1.StreamResponse) {
	for id, c := range s.clients {
		select {
		case c.events <- event:
		default:
			delete(s.clients, id)
			c.once.Do(func() {
				select {
				case c.terminal <- status.Error(codes.ResourceExhausted, "transcript subscriber queue exhausted"):
				default:
				}
				close(c.done)
			})
		}
	}
}
func (s *Service) terminateClients(err error) {
	s.mu.Lock()
	for id, c := range s.clients {
		select {
		case c.terminal <- err:
		default:
		}
		c.once.Do(func() { close(c.done) })
		delete(s.clients, id)
	}
	s.publishLocked()
	s.mu.Unlock()
}
func (s *Service) waitForStopSignal(pair *activePair) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return !s.demandLocked() || s.active != pair
}
func normalizeStopReason(reason string) string {
	switch reason {
	case "user", "muted", "no_clients", "max_duration", "shutdown", "capture_failure", "backend_failure", "native_failure":
		return reason
	default:
		return "muted"
	}
}
func sanitize(err error) string {
	if err == nil {
		return "operation failed"
	}
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "operation timed out"
	case errors.Is(err, ErrNativeDisconnected):
		return "native owner disconnected"
	default:
		return "operation failed"
	}
}
func newUUID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", fmt.Errorf("generate UUID: %w", err)
	}
	id[6] = (id[6] & 0x0f) | 0x40
	id[8] = (id[8] & 0x3f) | 0x80
	const h = "0123456789abcdef"
	var out [36]byte
	j := 0
	for i, b := range id {
		if i == 4 || i == 6 || i == 8 || i == 10 {
			out[j] = '-'
			j++
		}
		out[j] = h[b>>4]
		out[j+1] = h[b&15]
		j += 2
	}
	return string(out[:]), nil
}
func mustUUID(text string) [16]byte { id, _ := audio.ParseUUID(text); return id }
