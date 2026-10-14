// Package conversation provides microphone-only recognition alongside MISTT's
// unchanged paired relay. The native capture owner retains wake and AEC control.
package conversation

import (
	"context"
	"crypto/subtle"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"

	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"
	"github.com/sirerun/MISTT/internal/audio"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// Recognizer returns only after every supplied sample has been decoded. Empty
// text is a valid completed result; an error never establishes coverage.
type Recognizer interface {
	Recognize(context.Context, []byte, string) (string, error)
}

type Config struct {
	Token              string
	Model              string
	MaxUtterance       time.Duration
	MaxSession         time.Duration
	RecognitionTimeout time.Duration
}

type Server struct {
	misttv1.UnimplementedMisttServer
	cfg        Config
	recognizer Recognizer
}

func NewServer(cfg Config, recognizer Recognizer) (*Server, error) {
	if recognizer == nil || strings.TrimSpace(cfg.Model) == "" || len(cfg.Token) < 32 {
		return nil, errors.New("recognizer, model identity and explicit token of at least 32 bytes are required")
	}
	if cfg.MaxUtterance == 0 {
		cfg.MaxUtterance = 120 * time.Second
	}
	if cfg.MaxSession == 0 {
		cfg.MaxSession = 2 * time.Hour
	}
	if cfg.RecognitionTimeout == 0 {
		cfg.RecognitionTimeout = 15 * time.Second
	}
	if cfg.MaxUtterance < time.Second || cfg.MaxUtterance > 120*time.Second || cfg.MaxSession < time.Minute || cfg.MaxSession > 24*time.Hour || cfg.RecognitionTimeout <= 0 {
		return nil, errors.New("invalid conversation resource limits")
	}
	return &Server{cfg: cfg, recognizer: recognizer}, nil
}

func (s *Server) Conversation(stream misttv1.Mistt_ConversationServer) error {
	md, _ := metadata.FromIncomingContext(stream.Context())
	auth := md.Get("authorization")
	if len(auth) != 1 || subtle.ConstantTimeCompare([]byte(auth[0]), []byte("Bearer "+s.cfg.Token)) != 1 {
		return status.Error(codes.Unauthenticated, "conversation credential required")
	}
	// A single bounded receive pump lets expiry terminate even an idle client.
	type received struct {
		request *misttv1.ConversationRequest
		err     error
	}
	incoming := make(chan received, 1)
	done := make(chan struct{})
	defer close(done)
	go func() {
		for {
			request, err := stream.Recv()
			select {
			case incoming <- received{request, err}:
			case <-done:
				return
			case <-stream.Context().Done():
				return
			}
			if err != nil {
				return
			}
		}
	}()
	timer := time.NewTimer(s.cfg.MaxSession)
	defer timer.Stop()
	recv := func() (*misttv1.ConversationRequest, error) {
		select {
		case value := <-incoming:
			return value.request, value.err
		case <-timer.C:
			return nil, status.Error(codes.DeadlineExceeded, "conversation session renewal required")
		case <-stream.Context().Done():
			return nil, stream.Context().Err()
		}
	}
	first, err := recv()
	if err != nil {
		return err
	}
	start := first.GetStart()
	if start == nil || !audio.ValidUUIDText(start.SessionId) || start.Language != "en" {
		return status.Error(codes.InvalidArgument, "start requires a fresh UUID and English language")
	}
	if start.CaptureMode != misttv1.CaptureMode_CAPTURE_MODE_MICROPHONE {
		return status.Error(codes.FailedPrecondition, "Conversation admits microphone-only; armed capture must remain local")
	}
	var sequence, frameSequence, sample, covered, scheduled, activitySequence uint64
	var pending []byte
	speaking := false
	send := func(event *misttv1.StreamResponse) error {
		sequence++
		event.SessionId = start.SessionId
		event.Sequence = sequence
		return stream.Send(event)
	}
	if err := send(&misttv1.StreamResponse{Payload: &misttv1.StreamResponse_SessionStarted{SessionStarted: &misttv1.SessionStarted{Backend: "mistt.conversation.v1", Model: s.cfg.Model, Language: "en", SampleRateHz: 16000, Channels: 1, Encoding: "s16le", CaptureMode: start.CaptureMode, Sources: []*misttv1.SourceFormat{{Source: "microphone", SampleRateHz: 16000, Channels: 1, Encoding: "s16le"}}}}}); err != nil {
		return err
	}
	type decodeJob struct {
		start, end uint64
		pcm        []byte
	}
	type decodeResult struct {
		job  decodeJob
		text string
		err  error
	}
	jobs := make(chan decodeJob, 2)
	results := make(chan decodeResult, 1)
	workerCtx, stopWorker := context.WithCancel(stream.Context())
	defer stopWorker()
	go func() {
		for {
			select {
			case <-workerCtx.Done():
				return
			case job := <-jobs:
				ctx, cancel := context.WithTimeout(workerCtx, s.cfg.RecognitionTimeout)
				text, err := s.recognizer.Recognize(ctx, job.pcm, start.Language)
				cancel()
				select {
				case results <- decodeResult{job, text, err}:
				case <-workerCtx.Done():
					return
				}
			}
		}
	}()
	receiveInput := incoming
	outstanding := 0
	inputClosed := false
	publishResult := func(result decodeResult) error {
		if result.err != nil {
			return status.Error(codes.Unavailable, "local recognition failed; repeat the incomplete utterance")
		}
		if len(result.text) > 16384 {
			return status.Error(codes.ResourceExhausted, "recognition result exceeds transcript limit")
		}
		if strings.TrimSpace(result.text) != "" {
			activitySequence++
			t := &misttv1.TranscriptionEvent{Source: "microphone", SourceEventSequence: activitySequence, SegmentId: fmt.Sprintf("%s:%d", start.SessionId, result.job.start), Text: strings.TrimSpace(result.text), IsFinal: true, StartSample: result.job.start, EndSample: result.job.end, StartOffsetNs: result.job.start * 62500, EndOffsetNs: result.job.end * 62500}
			if err := send(&misttv1.StreamResponse{Payload: &misttv1.StreamResponse_Transcription{Transcription: t}}); err != nil {
				return err
			}
		}
		covered = result.job.end
		outstanding--
		return send(&misttv1.StreamResponse{Payload: &misttv1.StreamResponse_RecognitionProgress{RecognitionProgress: &misttv1.RecognitionProgress{Source: "microphone", FinalizedThroughOffsetNs: covered * 62500, FinalizedThroughSample: covered}}})
	}
	gap := func(reason string) error {
		if err := send(&misttv1.StreamResponse{Payload: &misttv1.StreamResponse_SessionGap{SessionGap: &misttv1.SessionGap{Source: "microphone", Reason: reason, StartOffsetNs: covered * 62500, EndOffsetNs: sample * 62500}}}); err != nil {
			return err
		}
		return status.Error(codes.DataLoss, reason)
	}
	for {
		if inputClosed && outstanding == 0 {
			if len(pending) > 0 {
				return gap("stream closed with unfinalized audio; repeat the incomplete utterance")
			}
			return send(&misttv1.StreamResponse{Payload: &misttv1.StreamResponse_SessionStopped{SessionStopped: &misttv1.SessionStopped{Reason: "client_closed"}}})
		}
		var value received
		// Give queued native observations priority over recognition completion.
		select {
		case value = <-receiveInput:
		default:
			select {
			case value = <-receiveInput:
			case result := <-results:
				if err := publishResult(result); err != nil {
					return err
				}
				continue
			case <-timer.C:
				return status.Error(codes.DeadlineExceeded, "conversation session renewal required")
			case <-stream.Context().Done():
				return stream.Context().Err()
			}
		}
		if value.err == io.EOF {
			inputClosed = true
			receiveInput = nil
			continue
		}
		if value.err != nil {
			return value.err
		}
		req := value.request

		switch value := req.Payload.(type) {
		case *misttv1.ConversationRequest_Audio:
			f := value.Audio
			if f == nil || len(f.Pcm16) == 0 || len(f.Pcm16)%2 != 0 || len(f.Pcm16) > 3200 {
				return status.Error(codes.InvalidArgument, "audio must be 1..1600 mono PCM16 samples")
			}
			if f.Sequence != frameSequence+1 || f.StartSample != sample {
				return gap("microphone sequence or sample discontinuity; new session required")
			}
			if len(pending)+len(f.Pcm16) > int(s.cfg.MaxUtterance.Seconds()*32000) {
				return gap("recognition checkpoint overdue; utterance exceeds limit")
			}
			pending = append(pending, f.Pcm16...)
			frameSequence = f.Sequence
			sample += uint64(len(f.Pcm16) / 2)
		case *misttv1.ConversationRequest_Activity:
			a := value.Activity
			if a == nil || a.CaptureSample > sample || a.CaptureSample < covered || a.Speaking == speaking {
				return status.Error(codes.InvalidArgument, "activity is outside unfinalized capture or repeats state")
			}
			speaking = a.Speaking
			activitySequence++
			activity := &misttv1.SpeechActivity{Source: "microphone", CaptureOffsetNs: a.CaptureSample * 62500, SourceEventSequence: activitySequence}
			e := &misttv1.StreamResponse{}
			if speaking {
				e.Payload = &misttv1.StreamResponse_SpeechStarted{SpeechStarted: activity}
			} else {
				e.Payload = &misttv1.StreamResponse_SpeechStopped{SpeechStopped: activity}
			}
			if err := send(e); err != nil {
				return err
			}
		case *misttv1.ConversationRequest_Checkpoint:
			c := value.Checkpoint
			if c == nil || c.ThroughSample != sample || sample == scheduled {
				return status.Error(codes.InvalidArgument, "checkpoint must cover exactly all new captured audio")
			}
			job := decodeJob{start: scheduled, end: sample, pcm: pending}
			select {
			case jobs <- job:
				outstanding++
				scheduled = sample
				pending = nil
			default:
				return gap("recognition queue exhausted; repeat the incomplete utterance")
			}
		default:
			return status.Error(codes.InvalidArgument, "only audio, activity and checkpoints follow admission")
		}
	}
}
