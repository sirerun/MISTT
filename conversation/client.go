package conversation

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"

	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
)

type ClientConfig struct {
	// Address is an explicit host:port. Plaintext is permitted only on loopback.
	Address, Token string
	TLS            *tls.Config
}
type Client struct {
	conn  *grpc.ClientConn
	token string
}

func NewClient(cfg ClientConfig) (*Client, error) {
	host, _, err := net.SplitHostPort(cfg.Address)
	if err != nil {
		return nil, fmt.Errorf("conversation address: %w", err)
	}
	if len(cfg.Token) < 32 || strings.ContainsAny(cfg.Token, "\r\n") {
		return nil, errors.New("conversation credential must contain at least 32 bytes")
	}
	var transport credentials.TransportCredentials
	if cfg.TLS != nil {
		copy := cfg.TLS.Clone()
		if copy.InsecureSkipVerify {
			return nil, errors.New("conversation TLS verification cannot be disabled")
		}
		if copy.MinVersion < tls.VersionTLS12 {
			copy.MinVersion = tls.VersionTLS12
		}
		transport = credentials.NewTLS(copy)
	} else {
		ip := net.ParseIP(host)
		if host != "localhost" && (ip == nil || !ip.IsLoopback()) {
			return nil, errors.New("non-loopback conversation endpoint requires TLS")
		}
		transport = insecure.NewCredentials()
	}
	conn, err := grpc.NewClient(cfg.Address, grpc.WithTransportCredentials(transport), grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(1<<20), grpc.MaxCallSendMsgSize(16384)))
	if err != nil {
		return nil, fmt.Errorf("create conversation transport: %w", err)
	}
	return &Client{conn: conn, token: cfg.Token}, nil
}
func (c *Client) Close() error { return c.conn.Close() }

type Stream struct {
	stream misttv1.Mistt_ConversationClient
	mu     sync.Mutex
	cancel context.CancelFunc
}

func (c *Client) Open(ctx context.Context, sessionID string) (*Stream, error) {
	ctx, cancel := context.WithCancel(metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+c.token))
	stream, err := misttv1.NewMisttClient(c.conn).Conversation(ctx)
	if err != nil {
		cancel()
		return nil, fmt.Errorf("open microphone stream: %w", err)
	}
	if err := stream.Send(&misttv1.ConversationRequest{Payload: &misttv1.ConversationRequest_Start{Start: &misttv1.ConversationStart{SessionId: sessionID, Language: "en", CaptureMode: misttv1.CaptureMode_CAPTURE_MODE_MICROPHONE}}}); err != nil {
		cancel()
		return nil, fmt.Errorf("admit microphone stream: %w", err)
	}
	return &Stream{stream: stream, cancel: cancel}, nil
}
func (s *Stream) SendPCM(sequence, startSample uint64, pcm16 []byte) error {
	return s.send(&misttv1.ConversationRequest{Payload: &misttv1.ConversationRequest_Audio{Audio: &misttv1.MicrophonePCM{Sequence: sequence, StartSample: startSample, Pcm16: pcm16}}})
}
func (s *Stream) Activity(speaking bool, captureSample uint64) error {
	return s.send(&misttv1.ConversationRequest{Payload: &misttv1.ConversationRequest_Activity{Activity: &misttv1.ConversationActivity{Speaking: speaking, CaptureSample: captureSample}}})
}
func (s *Stream) Checkpoint(throughSample uint64) error {
	return s.send(&misttv1.ConversationRequest{Payload: &misttv1.ConversationRequest_Checkpoint{Checkpoint: &misttv1.RecognitionCheckpoint{ThroughSample: throughSample}}})
}
func (s *Stream) send(request *misttv1.ConversationRequest) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.stream.Send(request)
}

// Recv must have one owner. EOF before SessionStopped is not successful completion.
func (s *Stream) Recv() (*misttv1.StreamResponse, error) { return s.stream.Recv() }
func (s *Stream) CloseSend() error                       { s.mu.Lock(); defer s.mu.Unlock(); return s.stream.CloseSend() }
func (s *Stream) Close() error                           { s.cancel(); return nil }
