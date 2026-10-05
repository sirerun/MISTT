package dgx

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
)

const protocol = "mistt.paired.v1"
const maxRemoteJSON = 1 << 20

var ErrQueueFull = errors.New("paired DGX per-source frame queue is full")

type Config struct {
	Endpoint, TokenFile, CAFile string
	QueueCap                    int
	WriteTimeout, DrainTimeout  time.Duration
}
type Client struct {
	cfg    Config
	dialer websocket.Dialer
}

func New(cfg Config) (*Client, error) {
	u, err := url.Parse(cfg.Endpoint)
	if err != nil || u.Scheme != "wss" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("DGX endpoint must be a credential-free wss URL")
	}
	if cfg.TokenFile == "" {
		return nil, errors.New("DGX restricted token file is required")
	}
	if cfg.QueueCap < 1 {
		cfg.QueueCap = 64
	}
	if cfg.WriteTimeout <= 0 {
		cfg.WriteTimeout = 2 * time.Second
	}
	if cfg.DrainTimeout <= 0 {
		cfg.DrainTimeout = 10 * time.Second
	}
	tlsConfig := &tls.Config{MinVersion: tls.VersionTLS12}
	if cfg.CAFile != "" {
		b, err := os.ReadFile(cfg.CAFile)
		if err != nil {
			return nil, fmt.Errorf("read DGX CA file: %w", err)
		}
		pool, err := x509.SystemCertPool()
		if err != nil || pool == nil {
			pool = x509.NewCertPool()
		}
		if !pool.AppendCertsFromPEM(b) {
			return nil, errors.New("DGX CA file contains no usable certificates")
		}
		tlsConfig.RootCAs = pool
	}
	return &Client{cfg: cfg, dialer: websocket.Dialer{TLSClientConfig: tlsConfig, HandshakeTimeout: 10 * time.Second}}, nil
}

type startWire struct {
	Type      string                 `json:"type"`
	Protocol  string                 `json:"protocol"`
	SessionID string                 `json:"session_id"`
	Language  string                 `json:"language"`
	Sources   []backend.SourceFormat `json:"sources"`
}
type sourceLimit struct {
	Source                   audio.Source `json:"source"`
	SampleRateHz             uint32       `json:"sample_rate_hz"`
	Channels                 uint32       `json:"channels"`
	Encoding                 string       `json:"encoding"`
	MaxFrameSamples          uint32       `json:"max_frame_samples"`
	MaxQueueFrames           uint32       `json:"max_queue_frames"`
	MaxAudioSamples          uint64       `json:"max_audio_samples"`
	MaxContextTokens         uint64       `json:"max_context_tokens"`
	DrainReserveModelSamples uint64       `json:"drain_reserve_model_samples"`
	DrainReserveTokens       uint64       `json:"drain_reserve_tokens"`
}
type readyWire struct {
	Type                              string        `json:"type"`
	Protocol                          string        `json:"protocol"`
	SessionID                         string        `json:"session_id"`
	Language                          string        `json:"language"`
	Model                             modelWire     `json:"model"`
	Sources                           []sourceLimit `json:"sources"`
	MaxActivePairs                    uint32        `json:"max_active_pairs"`
	AggregateMaxAudioSamples          uint64        `json:"aggregate_max_audio_samples"`
	AggregateMaxQueueFrames           uint64        `json:"aggregate_max_queue_frames"`
	AggregateMaxContextTokens         uint64        `json:"aggregate_max_context_tokens"`
	AggregateDrainReserveModelSamples uint64        `json:"aggregate_drain_reserve_model_samples"`
	AggregateDrainReserveTokens       uint64        `json:"aggregate_drain_reserve_tokens"`
	MaxInferenceWorkers               uint32        `json:"max_inference_workers"`
	StartupTimeoutMS                  uint32        `json:"startup_timeout_ms"`
	DrainTimeoutMS                    uint32        `json:"drain_timeout_ms"`
}
type modelWire struct {
	ID           string `json:"id"`
	Revision     string `json:"revision"`
	SourceCommit string `json:"source_commit"`
	SampleRate   uint32 `json:"sample_rate"`
	ChunkSamples uint32 `json:"chunk_samples"`
	Lookahead    uint32 `json:"lookahead_samples"`
}
type transcriptWire struct {
	Type                string       `json:"type"`
	SessionID           string       `json:"session_id"`
	Source              audio.Source `json:"source"`
	SourceEventSequence uint64       `json:"source_event_sequence"`
	SegmentID           string       `json:"segment_id"`
	Text                string       `json:"text"`
	Final               bool         `json:"is_final"`
	Confidence          float64      `json:"confidence"`
	StartSample         uint64       `json:"start_sample"`
	EndSample           uint64       `json:"end_sample"`
	StartOffsetNS       uint64       `json:"start_offset_ns"`
	EndOffsetNS         uint64       `json:"end_offset_ns"`
}
type sourceEndWire struct {
	Type           string       `json:"type"`
	SessionID      string       `json:"session_id"`
	Source         audio.Source `json:"source"`
	LastSequence   uint64       `json:"last_sequence"`
	TotalSamples   uint64       `json:"total_samples"`
	CutoffOffsetNS uint64       `json:"cutoff_offset_ns"`
}
type sourceDoneWire struct {
	Type      string       `json:"type"`
	SessionID string       `json:"session_id"`
	Source    audio.Source `json:"source"`
	Success   bool         `json:"success"`
	Code      *string      `json:"code"`
	Detail    *string      `json:"detail"`
}
type captureStartedWire struct {
	RequestID          string                 `json:"request_id"`
	Type               string                 `json:"type"`
	SessionID          string                 `json:"session_id"`
	CaptureEpochHostNS uint64                 `json:"capture_epoch_host_ns"`
	CaptureEpochUnixMS int64                  `json:"capture_epoch_unix_ms"`
	Sources            []backend.SourceFormat `json:"sources"`
	MicrophoneReady    bool                   `json:"microphone_ready"`
	CallAudioReady     bool                   `json:"call_audio_ready"`
}

type ClientSession struct {
	conn      *websocket.Conn
	ready     backend.Ready
	cfg       Config
	mic       chan audio.Frame
	call      chan audio.Frame
	mu        sync.Mutex
	ended     map[audio.Source]bool
	ends      map[audio.Source]backend.EndRequest
	limits    map[audio.Source]sourceLimit
	queued    map[audio.Source]backend.EndRequest
	cutoffSet bool
	cutoffNS  uint64
	events    chan backend.Event
	closed    chan struct{}
	once      sync.Once
	writeDone chan error
}

func (c *Client) Connect(ctx context.Context, req backend.StartRequest) (backend.Session, error) {
	if req.SessionID == "" || !audio.ValidUUIDText(req.SessionID) {
		return nil, errors.New("DGX session ID must be a UUID")
	}
	if req.Language == "" {
		return nil, errors.New("DGX language is required")
	}
	token, err := readRestrictedToken(c.cfg.TokenFile)
	if err != nil {
		return nil, fmt.Errorf("read restricted DGX credential: %w", err)
	}
	token = strings.TrimSpace(token)
	if token == "" || strings.ContainsAny(token, "\r\n") {
		return nil, errors.New("DGX credential is empty or malformed")
	}
	u, _ := url.Parse(c.cfg.Endpoint)
	header := http.Header{}
	header.Set("Authorization", "Bearer "+token)
	conn, resp, err := c.dialer.DialContext(ctx, u.String(), header)
	if err != nil {
		if resp != nil {
			return nil, fmt.Errorf("open DGX wss (HTTP %d): %w", resp.StatusCode, err)
		}
		return nil, fmt.Errorf("open DGX wss: %w", err)
	}
	conn.SetReadLimit(maxRemoteJSON)
	if d, ok := ctx.Deadline(); ok {
		_ = conn.SetReadDeadline(d)
	}
	formats := []backend.SourceFormat{{Source: audio.Microphone, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}, {Source: audio.CallAudio, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}}
	if err := conn.SetWriteDeadline(time.Now().Add(c.dialer.HandshakeTimeout)); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("set paired start deadline: %w", err)
	}
	if err := conn.WriteJSON(startWire{Type: "start", Protocol: protocol, SessionID: req.SessionID, Language: req.Language, Sources: formats}); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("send paired DGX start: %w", err)
	}
	if err := conn.SetWriteDeadline(time.Time{}); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("clear paired start deadline: %w", err)
	}
	var ready readyWire
	if err := readStrictJSON(conn, &ready, "type", "protocol", "session_id", "language", "model", "sources", "max_active_pairs", "aggregate_max_audio_samples", "aggregate_max_queue_frames", "aggregate_max_context_tokens", "aggregate_drain_reserve_model_samples", "aggregate_drain_reserve_tokens", "max_inference_workers", "startup_timeout_ms", "drain_timeout_ms"); err != nil {
		_ = conn.Close()
		return nil, fmt.Errorf("read paired DGX ready: %w", err)
	}
	if err := validateReady(ready, req, formats); err != nil {
		_ = conn.Close()
		return nil, err
	}
	_ = conn.SetReadDeadline(time.Time{})
	capMic, capCall := c.cfg.QueueCap, c.cfg.QueueCap
	for _, s := range ready.Sources {
		cap := int(s.MaxQueueFrames)
		if cap < c.cfg.QueueCap {
			if s.Source == audio.Microphone {
				capMic = cap
			} else {
				capCall = cap
			}
		}
	}
	limits := map[audio.Source]sourceLimit{ready.Sources[0].Source: ready.Sources[0], ready.Sources[1].Source: ready.Sources[1]}
	s := &ClientSession{conn: conn, cfg: c.cfg, ready: backend.Ready{SessionID: ready.SessionID, Model: ready.Model.ID + "@" + ready.Model.Revision, Language: ready.Language, Sources: formats, MaxActivePairs: ready.MaxActivePairs, StartupTimeoutMS: ready.StartupTimeoutMS, DrainTimeoutMS: ready.DrainTimeoutMS}, mic: make(chan audio.Frame, capMic), call: make(chan audio.Frame, capCall), ended: map[audio.Source]bool{}, ends: map[audio.Source]backend.EndRequest{}, limits: limits, queued: map[audio.Source]backend.EndRequest{}, events: make(chan backend.Event, 32), closed: make(chan struct{}), writeDone: make(chan error, 1)}
	go s.writeLoop()
	go s.readLoop()
	return s, nil
}

func readRestrictedToken(path string) (string, error) {
	before, err := os.Lstat(path)
	if err != nil {
		return "", err
	}
	if before.Mode()&os.ModeSymlink != 0 || !before.Mode().IsRegular() || before.Mode().Perm()&0077 != 0 {
		return "", errors.New("token must be a nonsymlink regular file with permissions no broader than 0600")
	}
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	after, err := f.Stat()
	if err != nil {
		return "", err
	}
	if !os.SameFile(before, after) || !after.Mode().IsRegular() || after.Mode().Perm()&0077 != 0 {
		return "", errors.New("token file changed or is not restricted")
	}
	data, err := io.ReadAll(io.LimitReader(f, 4097))
	if err != nil {
		return "", err
	}
	if len(data) == 0 || len(data) > 4096 {
		return "", errors.New("token file is empty or exceeds 4096 bytes")
	}
	return string(data), nil
}
func validateReady(r readyWire, req backend.StartRequest, want []backend.SourceFormat) error {
	if r.Type != "ready" || r.Protocol != protocol || r.SessionID != req.SessionID || r.Language != req.Language || r.Model.ID == "" || r.Model.Revision == "" || r.Model.SourceCommit == "" || r.Model.SampleRate == 0 || r.Model.ChunkSamples == 0 || r.Model.Lookahead > r.Model.SampleRate || r.MaxActivePairs != 1 || r.AggregateMaxAudioSamples == 0 || r.AggregateMaxQueueFrames == 0 || r.AggregateMaxContextTokens == 0 || r.MaxInferenceWorkers != 1 || r.StartupTimeoutMS == 0 || r.DrainTimeoutMS == 0 || len(r.Sources) != 2 {
		return errors.New("DGX ready violates paired protocol or admission requirements")
	}
	if len(want) != 2 || r.Sources[0].Source != want[0].Source || r.Sources[1].Source != want[1].Source {
		return errors.New("DGX ready sources are not in canonical microphone, call_audio order")
	}
	seen := map[audio.Source]bool{}
	var aggregateQueues, aggregateContexts uint64
	var aggregateDrainSamples, aggregateDrainTokens uint64
	for _, s := range r.Sources {
		if !s.Source.Valid() || seen[s.Source] {
			return errors.New("DGX ready contains missing, duplicate or unknown source")
		}
		seen[s.Source] = true
		if s.SampleRateHz != audio.SampleRate || s.Channels != audio.Channels || s.Encoding != audio.Encoding || s.MaxFrameSamples == 0 || s.MaxFrameSamples > audio.MaxSamples || s.MaxQueueFrames == 0 || s.MaxAudioSamples == 0 || s.MaxContextTokens == 0 {
			return fmt.Errorf("DGX ready has invalid limits for %s", s.Source)
		}
		aggregateQueues += uint64(s.MaxQueueFrames)
		if aggregateContexts > math.MaxUint64-s.MaxContextTokens {
			return errors.New("paired ready aggregate context budget overflows")
		}
		aggregateContexts += s.MaxContextTokens
		if s.DrainReserveModelSamples > s.MaxAudioSamples || s.DrainReserveTokens > s.MaxContextTokens {
			return fmt.Errorf("DGX drain reserve exceeds per-source limits for %s", s.Source)
		}
		if s.DrainReserveModelSamples > ^uint64(0)-aggregateDrainSamples || s.DrainReserveTokens > ^uint64(0)-aggregateDrainTokens {
			return errors.New("DGX aggregate drain reserve overflows")
		}
		aggregateDrainSamples += s.DrainReserveModelSamples
		aggregateDrainTokens += s.DrainReserveTokens
	}
	if !seen[audio.Microphone] || !seen[audio.CallAudio] {
		return errors.New("DGX ready did not admit both sources")
	}
	if aggregateQueues > r.AggregateMaxQueueFrames || aggregateContexts > r.AggregateMaxContextTokens || r.Sources[0].MaxAudioSamples > r.AggregateMaxAudioSamples || r.Sources[1].MaxAudioSamples > r.AggregateMaxAudioSamples-r.Sources[0].MaxAudioSamples || aggregateDrainSamples > r.AggregateMaxAudioSamples || aggregateDrainTokens > r.AggregateMaxContextTokens || aggregateDrainSamples > r.AggregateDrainReserveModelSamples || aggregateDrainTokens > r.AggregateDrainReserveTokens {
		return errors.New("DGX per-source limits exceed aggregate admission caps")
	}
	for i, source := range r.Sources {
		if source.SampleRateHz != want[i].SampleRateHz || source.Channels != want[i].Channels || source.Encoding != want[i].Encoding {
			return fmt.Errorf("DGX ready format mismatch for %s", source.Source)
		}
	}
	return nil
}
func readStrictJSON(conn *websocket.Conn, dst any, required ...string) error {
	kind, data, err := conn.ReadMessage()
	if err != nil {
		return err
	}
	if kind != websocket.TextMessage {
		return errors.New("DGX handshake must be a text JSON message")
	}
	if len(data) > maxRemoteJSON {
		return errors.New("DGX handshake exceeds JSON size limit")
	}
	return strictJSON(data, dst, required...)
}
func (s *ClientSession) Ready() backend.Ready         { return s.ready }
func (s *ClientSession) Events() <-chan backend.Event { return s.events }
func (s *ClientSession) CaptureStarted(ack backend.CaptureStarted) error {
	want := []backend.SourceFormat{{Source: audio.Microphone, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}, {Source: audio.CallAudio, SampleRateHz: audio.SampleRate, Channels: audio.Channels, Encoding: audio.Encoding}}
	if !audio.ValidUUIDText(ack.RequestID) || ack.CaptureEpochHostNS == 0 || ack.CaptureEpochUnixMS <= 0 || !ack.MicrophoneReady || !ack.CallAudioReady || len(ack.Sources) != 2 || ack.Sources[0] != want[0] || ack.Sources[1] != want[1] {
		return errors.New("capture_started requires correlated request, positive epochs, both ready sources, and canonical paired formats")
	}
	return s.writeJSON(captureStartedWire{Type: "capture_started", RequestID: ack.RequestID, SessionID: s.ready.SessionID, CaptureEpochHostNS: ack.CaptureEpochHostNS, CaptureEpochUnixMS: ack.CaptureEpochUnixMS, Sources: ack.Sources, MicrophoneReady: ack.MicrophoneReady, CallAudioReady: ack.CallAudioReady})
}
func (s *ClientSession) QueueFrame(f audio.Frame) error {
	if err := f.Validate(); err != nil {
		return err
	}
	wantID, err := audio.ParseUUID(s.ready.SessionID)
	if err != nil || f.SessionID != wantID {
		return errors.New("audio frame session does not match paired WSS generation")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	select {
	case <-s.closed:
		return errors.New("DGX session is closed")
	default:
	}
	if s.ended[f.Source] {
		return fmt.Errorf("audio arrived after %s EOF", f.Source)
	}
	q := s.mic
	if f.Source == audio.CallAudio {
		q = s.call
	}
	limit := s.limits[f.Source]
	ledger := s.queued[f.Source]
	if ledger.LastSequence == math.MaxUint64 || ledger.TotalSamples > limit.MaxAudioSamples {
		return fmt.Errorf("%s audio ledger is exhausted", f.Source)
	}
	if uint32(len(f.Samples)) > limit.MaxFrameSamples {
		return fmt.Errorf("%s frame exceeds gateway frame cap", f.Source)
	}
	if ledger.LastSequence == math.MaxUint64 || f.Sequence != ledger.LastSequence+1 || f.StartSample != ledger.TotalSamples {
		return fmt.Errorf("%s queue has a source sequence gap", f.Source)
	}
	if uint64(len(f.Samples)) > limit.MaxAudioSamples-ledger.TotalSamples {
		return fmt.Errorf("%s audio exceeds gateway audio cap", f.Source)
	}
	select {
	case q <- f:
		ledger.LastSequence = f.Sequence
		ledger.TotalSamples += uint64(len(f.Samples))
		s.queued[f.Source] = ledger
		return nil
	default:
		return ErrQueueFull
	}
}
func (s *ClientSession) EndSource(source audio.Source, e backend.EndRequest) error {
	if !source.Valid() {
		return errors.New("unknown source EOF")
	}
	if (e.LastSequence == 0) != (e.TotalSamples == 0) {
		return errors.New("source EOF totals are inconsistent")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ended[source] {
		return fmt.Errorf("duplicate %s EOF", source)
	}
	select {
	case <-s.closed:
		return errors.New("DGX session is closed")
	default:
	}
	if e.LastSequence != s.queued[source].LastSequence || e.TotalSamples != s.queued[source].TotalSamples {
		return fmt.Errorf("%s EOF totals disagree with queued gateway ledger", source)
	}
	if s.cutoffSet && s.cutoffNS != e.CutoffOffsetNS {
		return errors.New("paired source_end cutoff offsets disagree")
	}
	s.cutoffSet = true
	s.cutoffNS = e.CutoffOffsetNS
	s.ended[source] = true
	s.ends[source] = e
	if source == audio.Microphone {
		close(s.mic)
	} else {
		close(s.call)
	}
	return nil
}
func (s *ClientSession) Close() error {
	s.once.Do(func() { close(s.closed); _ = s.conn.Close() })
	return nil
}
func (s *ClientSession) writeLoop() {
	mic, call := s.mic, s.call
	sent := map[audio.Source]backend.EndRequest{}
	for mic != nil || call != nil {
		select {
		case f, ok := <-mic:
			if !ok {
				if err := s.writeSourceEnd(audio.Microphone, s.ends[audio.Microphone], sent[audio.Microphone]); err != nil {
					s.finish(err)
					return
				}
				mic = nil
				continue
			}
			if err := s.writeFrame(f); err != nil {
				s.finish(err)
				return
			}
			sent[audio.Microphone] = backend.EndRequest{LastSequence: f.Sequence, TotalSamples: f.StartSample + uint64(len(f.Samples))}
		case f, ok := <-call:
			if !ok {
				if err := s.writeSourceEnd(audio.CallAudio, s.ends[audio.CallAudio], sent[audio.CallAudio]); err != nil {
					s.finish(err)
					return
				}
				call = nil
				continue
			}
			if err := s.writeFrame(f); err != nil {
				s.finish(err)
				return
			}
			sent[audio.CallAudio] = backend.EndRequest{LastSequence: f.Sequence, TotalSamples: f.StartSample + uint64(len(f.Samples))}
		case <-s.closed:
			return
		}
	}
	select {
	case <-s.closed:
		return
	default:
	}
	s.writeDone <- nil
}
func (s *ClientSession) writeFrame(f audio.Frame) error {
	b, err := f.MarshalBinary()
	if err != nil {
		return err
	}
	if err := s.conn.SetWriteDeadline(time.Now().Add(s.cfg.WriteTimeout)); err != nil {
		return err
	}
	if err := s.conn.WriteMessage(websocket.BinaryMessage, b); err != nil {
		return fmt.Errorf("write DGX %s audio: %w", f.Source, err)
	}
	return nil
}
func (s *ClientSession) writeSourceEnd(source audio.Source, want, sent backend.EndRequest) error {
	if want.LastSequence != sent.LastSequence || want.TotalSamples != sent.TotalSamples {
		return fmt.Errorf("%s source_end totals do not match transmitted audio", source)
	}
	return s.writeJSON(sourceEndWire{Type: "source_end", SessionID: s.ready.SessionID, Source: source, LastSequence: sent.LastSequence, TotalSamples: sent.TotalSamples, CutoffOffsetNS: want.CutoffOffsetNS})
}
func (s *ClientSession) writeJSON(value any) error {
	if err := s.conn.SetWriteDeadline(time.Now().Add(s.cfg.WriteTimeout)); err != nil {
		return err
	}
	if err := s.conn.WriteJSON(value); err != nil {
		return fmt.Errorf("write DGX control: %w", err)
	}
	return nil
}
func (s *ClientSession) finish(err error) {
	s.once.Do(func() {
		close(s.closed)
		_ = s.conn.Close()
		select {
		case s.events <- backend.Event{Err: err}:
		default:
		}
	})
}
func (s *ClientSession) readLoop() {
	defer close(s.events)
	sourceSeq := map[audio.Source]uint64{}
	done := map[audio.Source]bool{}
	for {
		kind, data, err := s.conn.ReadMessage()
		if err != nil {
			select {
			case <-s.closed:
				return
			default:
			}
			s.emit(backend.Event{Err: fmt.Errorf("DGX stream read: %w", err)})
			return
		}
		if len(data) > maxRemoteJSON {
			s.emit(backend.Event{Err: errors.New("DGX JSON exceeds message limit")})
			return
		}
		if kind != websocket.TextMessage {
			s.emit(backend.Event{Err: errors.New("DGX sent unsupported non-text message")})
			return
		}
		event, err := decodeRemoteEvent(data, s.ready.SessionID)
		if err != nil {
			s.emit(backend.Event{Err: err})
			return
		}
		if event.Transcript != nil {
			t := event.Transcript
			if t.SourceEventSequence <= sourceSeq[t.Source] {
				s.emit(backend.Event{Err: fmt.Errorf("DGX %s event sequence is stale", t.Source)})
				return
			}
			sourceSeq[t.Source] = t.SourceEventSequence
		}
		if event.SourceDone != nil {
			src := event.SourceDone.Source
			if done[src] {
				s.emit(backend.Event{Err: fmt.Errorf("duplicate DGX %s source_done", src)})
				return
			}
			done[src] = true
			if !event.SourceDone.Success {
				s.emit(event)
				return
			}
		}
		if event.Done {
			if !done[audio.Microphone] || !done[audio.CallAudio] {
				s.emit(backend.Event{Err: errors.New("DGX overall done before both source_done results")})
				return
			}
			s.emit(event)
			return
		}
		if !s.emit(event) {
			return
		}
	}
}
func (s *ClientSession) emit(e backend.Event) bool {
	select {
	case s.events <- e:
		return true
	case <-s.closed:
		return false
	default:
		select {
		case s.events <- backend.Event{Err: errors.New("DGX event queue overflow")}:
		default:
		}
		return false
	}
}
func decodeRemoteEvent(data []byte, session string) (backend.Event, error) {
	fields, err := remoteObject(data)
	if err != nil {
		return backend.Event{}, err
	}
	var typ struct {
		Type      string `json:"type"`
		SessionID string `json:"session_id"`
	}
	if err := json.Unmarshal(fields["type"], &typ.Type); err != nil {
		return backend.Event{}, errors.New("DGX event has no valid type")
	}
	if err := json.Unmarshal(fields["session_id"], &typ.SessionID); err != nil {
		return backend.Event{}, err
	}
	if typ.SessionID != session {
		return backend.Event{}, errors.New("DGX event session ID mismatch")
	}
	switch typ.Type {
	case "transcript":
		var t transcriptWire
		if err := strictJSON(data, &t, "type", "session_id", "source", "source_event_sequence", "segment_id", "text", "is_final", "confidence", "start_sample", "end_sample", "start_offset_ns", "end_offset_ns"); err != nil {
			return backend.Event{}, err
		}
		if !t.Source.Valid() || t.SourceEventSequence == 0 || t.SegmentID == "" || t.EndSample < t.StartSample || t.EndOffsetNS < t.StartOffsetNS || math.IsNaN(t.Confidence) || math.IsInf(t.Confidence, 0) {
			return backend.Event{}, errors.New("DGX transcript fields are invalid")
		}
		return backend.Event{Transcript: &backend.Transcript{Source: t.Source, SourceEventSequence: t.SourceEventSequence, SegmentID: t.SegmentID, Text: t.Text, Final: t.Final, Confidence: t.Confidence, StartSample: t.StartSample, EndSample: t.EndSample, StartOffsetNS: t.StartOffsetNS, EndOffsetNS: t.EndOffsetNS}}, nil
	case "source_done":
		var d sourceDoneWire
		if err := strictJSON(data, &d, "type", "session_id", "source", "success", "code", "detail"); err != nil {
			return backend.Event{}, err
		}
		if !d.Source.Valid() {
			return backend.Event{}, errors.New("DGX source_done source is invalid")
		}
		if d.Success && (d.Code != nil || d.Detail != nil) {
			return backend.Event{}, errors.New("successful source_done must carry null code and detail")
		}
		code, detail := "", ""
		if d.Code != nil {
			code = *d.Code
		}
		if d.Detail != nil {
			detail = *d.Detail
		}
		return backend.Event{SourceDone: &backend.SourceCompletion{Source: d.Source, Success: d.Success, Code: code, Detail: detail}}, nil
	case "done":
		if err := strictJSON(data, &typ, "type", "session_id"); err != nil {
			return backend.Event{}, err
		}
		return backend.Event{Done: true}, nil
	default:
		return backend.Event{}, fmt.Errorf("unexpected DGX event type %q", typ.Type)
	}
}
func strictJSON(data []byte, dst any, required ...string) error {
	if err := rejectDuplicateJSON(data); err != nil {
		return err
	}
	fields, err := remoteObject(data)
	if err != nil {
		return err
	}
	for _, key := range required {
		value, ok := fields[key]
		if !ok {
			return fmt.Errorf("remote JSON is missing required field %q", key)
		}
		if strings.TrimSpace(string(value)) == "null" && key != "code" && key != "detail" {
			return fmt.Errorf("remote JSON field %q cannot be null", key)
		}
	}
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.DisallowUnknownFields()
	dec.UseNumber()
	if err := dec.Decode(dst); err != nil {
		return err
	}
	if dec.Decode(new(any)) != io.EOF {
		return errors.New("DGX JSON has trailing content")
	}
	return nil
}
func rejectDuplicateJSON(data []byte) error {
	dec := json.NewDecoder(strings.NewReader(string(data)))
	dec.UseNumber()
	var value func() error
	value = func() error {
		tok, err := dec.Token()
		if err != nil {
			return err
		}
		delim, ok := tok.(json.Delim)
		if !ok {
			return nil
		}
		switch delim {
		case '{':
			seen := map[string]bool{}
			for dec.More() {
				keyToken, err := dec.Token()
				if err != nil {
					return err
				}
				key, ok := keyToken.(string)
				if !ok {
					return errors.New("DGX JSON object has invalid key")
				}
				if seen[key] {
					return fmt.Errorf("DGX message repeats nested field %q", key)
				}
				seen[key] = true
				if err := value(); err != nil {
					return err
				}
			}
			_, err = dec.Token()
			return err
		case '[':
			for dec.More() {
				if err := value(); err != nil {
					return err
				}
			}
			_, err = dec.Token()
			return err
		default:
			return errors.New("DGX JSON has unexpected closing delimiter")
		}
	}
	if err := value(); err != nil {
		return err
	}
	if _, err := dec.Token(); err != io.EOF {
		return errors.New("DGX JSON has trailing content")
	}
	return nil
}
func remoteObject(data []byte) (map[string]json.RawMessage, error) {
	dec := json.NewDecoder(strings.NewReader(string(data)))
	tok, err := dec.Token()
	if err != nil || tok != json.Delim('{') {
		return nil, errors.New("DGX message must be a JSON object")
	}
	fields := map[string]json.RawMessage{}
	for dec.More() {
		tok, err = dec.Token()
		if err != nil {
			return nil, err
		}
		key, ok := tok.(string)
		if !ok {
			return nil, errors.New("DGX message has invalid key")
		}
		if _, exists := fields[key]; exists {
			return nil, fmt.Errorf("DGX message repeats field %q", key)
		}
		var value json.RawMessage
		if err := dec.Decode(&value); err != nil {
			return nil, err
		}
		fields[key] = value
	}
	if _, err = dec.Token(); err != nil {
		return nil, err
	}
	if dec.Decode(new(any)) != io.EOF {
		return nil, errors.New("DGX message has trailing JSON")
	}
	return fields, nil
}
