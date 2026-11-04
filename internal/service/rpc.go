package service

import (
	"context"
	"fmt"
	"io"
	"strings"
	"time"

	"github.com/sirerun/MISTT/gen/mistt/v1"
	"github.com/sirerun/MISTT/internal/audio"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

func (s *Service) StreamTranscription(stream misttv1.Mistt_StreamTranscriptionServer) error {
	first, err := stream.Recv()
	if err != nil {
		return err
	}
	subscribe := first.GetSubscribe()
	if subscribe == nil || strings.TrimSpace(subscribe.Language) == "" {
		return status.Error(codes.InvalidArgument, "first message must subscribe with a language")
	}
	if subscribe.CaptureMode != misttv1.CaptureMode_CAPTURE_MODE_LEGACY_PAIRED && subscribe.CaptureMode != misttv1.CaptureMode_CAPTURE_MODE_PAIRED {
		return status.Error(codes.FailedPrecondition, "paired relay does not admit microphone or armed mode; use native Conversation")
	}
	sub, err := s.addSubscriber(stream.Context(), subscribe.Language)
	if err != nil {
		return err
	}
	defer s.removeSubscriber(sub)
	clientErr := make(chan error, 1)
	go func() {
		for {
			msg, err := stream.Recv()
			if err == io.EOF {
				clientErr <- nil
				return
			}
			if err != nil {
				clientErr <- err
				return
			}
			if msg.GetKeepAlive() == nil {
				clientErr <- status.Error(codes.InvalidArgument, "only keep_alive is allowed after subscribe")
				return
			}
		}
	}()
	for {
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case err := <-clientErr:
			if err != nil {
				return err
			}
			clientErr = nil
		case <-sub.done:
			select {
			case err := <-sub.terminal:
				return err
			default:
				return nil
			}
		case event, ok := <-sub.events:
			if !ok {
				return nil
			}
			if err := stream.Send(event); err != nil {
				return err
			}
		}
	}
}
func (s *Service) WatchStatus(_ *misttv1.WatchStatusRequest, stream misttv1.Mistt_WatchStatusServer) error {
	for {
		s.mu.Lock()
		current := s.statusLocked()
		changed := s.statusChanged
		s.mu.Unlock()
		if err := stream.Send(current); err != nil {
			return err
		}
		select {
		case <-stream.Context().Done():
			return stream.Context().Err()
		case <-s.closed:
			return nil
		case <-changed:
		}
	}
}
func (s *Service) SetMuted(ctx context.Context, req *misttv1.SetMutedRequest) (*misttv1.Status, error) {
	if req == nil {
		return nil, status.Error(codes.InvalidArgument, "mute request is required")
	}
	if !audio.ValidUUIDText(req.RequestId) {
		return nil, status.Error(codes.InvalidArgument, "mute request_id must be a UUID")
	}
	payload := fmt.Sprintf("%t|%d", req.Muted, req.ExpectedRevision)
	s.mu.Lock()
	if previous, ok := s.muteRequests[req.RequestId]; ok {
		if previous.payload != payload {
			s.mu.Unlock()
			return nil, status.Error(codes.InvalidArgument, "mute request_id was reused with a different payload")
		}
		done := previous.done
		s.mu.Unlock()
		select {
		case <-ctx.Done():
			return nil, status.Error(codes.DeadlineExceeded, "timed out waiting for the original mute request")
		case <-done:
		}
		s.mu.Lock()
		result, code, detail := cloneStatus(previous.result), previous.code, previous.detail
		s.mu.Unlock()
		if code != codes.OK {
			return result, status.Error(code, detail)
		}
		return result, nil
	}
	if len(s.muteRequests) >= 128 {
		s.pruneMuteRequestsLocked(127)
	}
	if len(s.muteRequests) >= 128 {
		s.mu.Unlock()
		return nil, status.Error(codes.ResourceExhausted, "mute request cache is full")
	}
	record := &muteRecord{payload: payload, done: make(chan struct{})}
	s.muteRequests[req.RequestId] = record
	s.muteOrder = append(s.muteOrder, req.RequestId)
	s.mu.Unlock()
	result, callErr := s.setMuted(ctx, req)
	s.mu.Lock()
	record.result = cloneStatus(result)
	if callErr != nil {
		converted := status.Convert(callErr)
		record.code, record.detail = converted.Code(), converted.Message()
	} else {
		record.code = codes.OK
	}
	record.complete = true
	close(record.done)
	s.pruneMuteRequestsLocked(128)
	s.mu.Unlock()
	return result, callErr
}

func (s *Service) pruneMuteRequestsLocked(maxEntries int) {
	for len(s.muteRequests) > maxEntries {
		removed := false
		for i, id := range s.muteOrder {
			if record, ok := s.muteRequests[id]; ok && record.complete {
				delete(s.muteRequests, id)
				s.muteOrder = append(s.muteOrder[:i], s.muteOrder[i+1:]...)
				removed = true
				break
			}
		}
		if !removed {
			return
		}
	}
}

func cloneStatus(value *misttv1.Status) *misttv1.Status {
	if value == nil {
		return nil
	}
	return proto.Clone(value).(*misttv1.Status)
}

func (s *Service) setMuted(ctx context.Context, req *misttv1.SetMutedRequest) (*misttv1.Status, error) {
	s.mu.Lock()
	if s.shutdownRequested {
		s.mu.Unlock()
		return nil, status.Error(codes.Unavailable, "relay is shutting down")
	}
	if req.ExpectedRevision == 0 || req.ExpectedRevision != s.revision {
		snapshot := s.statusLocked()
		s.mu.Unlock()
		return snapshot, status.Error(codes.Aborted, "status revision conflict")
	}
	if !req.Muted && s.updateReserved {
		s.mu.Unlock()
		return nil, status.Error(codes.FailedPrecondition, "update reservation blocks unmute")
	}
	if !req.Muted && !s.closureConfirmed {
		s.mu.Unlock()
		return nil, status.Error(codes.FailedPrecondition, "paired capture closure is unconfirmed")
	}
	if s.muted != req.Muted {
		s.muted = req.Muted
		if !req.Muted {
			s.budgetStarted = time.Time{}
			s.budgetRotations = 0
		}
		if req.Muted {
			s.reason = "user"
		} else {
			s.reason = "armed"
		}
		s.publishLocked()
		s.signalLocked()
	}
	cancelStart := s.startCancel
	snapshot := s.statusLocked()
	needWait := req.Muted && (s.active != nil || s.starting || s.stopping || s.capturing || !s.closureConfirmed)
	wait := s.statusChanged
	s.mu.Unlock()
	if cancelStart != nil {
		cancelStart()
	}
	if !needWait {
		return snapshot, nil
	}
	for {
		select {
		case <-ctx.Done():
			return nil, status.Error(codes.DeadlineExceeded, "timed out waiting for native paired closure ACK")
		case <-s.closed:
			return nil, status.Error(codes.Unavailable, "native owner disconnected")
		case <-wait:
			s.mu.Lock()
			snapshot := s.statusLocked()
			if s.active == nil && !s.starting && !s.stopping && !s.capturing && s.closureConfirmed {
				s.mu.Unlock()
				return snapshot, nil
			}
			wait = s.statusChanged
			s.mu.Unlock()
		}
	}
}
func (s *Service) addSubscriber(ctx context.Context, language string) (*subscriber, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	if strings.TrimSpace(language) != s.cfg.Language {
		return nil, status.Error(codes.FailedPrecondition, "subscriber language is not admitted by the paired gateway")
	}
	s.mu.Lock()
	select {
	case <-s.closed:
		s.mu.Unlock()
		return nil, status.Error(codes.Unavailable, "relay is shutting down")
	default:
	}
	if s.shutdownRequested {
		s.mu.Unlock()
		return nil, status.Error(codes.Unavailable, "relay is shutting down")
	}
	for _, existing := range s.clients {
		if existing.language != language {
			s.mu.Unlock()
			return nil, status.Error(codes.FailedPrecondition, "subscribers must use one shared language")
		}
	}
	s.nextClient++
	sub := &subscriber{id: s.nextClient, language: language, events: make(chan *misttv1.StreamResponse, s.cfg.ClientBuffer), done: make(chan struct{}), terminal: make(chan error, 1)}
	if s.active != nil && s.active.started != nil {
		sub.events <- proto.Clone(s.active.started).(*misttv1.StreamResponse)
	}
	s.clients[sub.id] = sub
	if len(s.clients) == 1 && !s.muted {
		s.reason = "armed"
	}
	s.publishLocked()
	s.signalLocked()
	s.mu.Unlock()
	return sub, nil
}
func (s *Service) removeSubscriber(sub *subscriber) {
	s.mu.Lock()
	var cancel context.CancelFunc
	if _, ok := s.clients[sub.id]; ok {
		delete(s.clients, sub.id)
		sub.once.Do(func() { close(sub.done) })
		if len(s.clients) == 0 && !s.muted {
			s.reason = "no_clients"
			cancel = s.startCancel
		}
		s.publishLocked()
		s.signalLocked()
	}
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}
