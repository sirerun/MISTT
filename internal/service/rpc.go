package service

import (
	"context"
	"io"
	"strings"

	"github.com/sirerun/MISTT/gen/mistt/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
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
	needWait := req.Muted && s.capturing
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
			if !s.capturing && s.closureConfirmed {
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
		clone := *s.active.started
		sub.events <- &clone
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
