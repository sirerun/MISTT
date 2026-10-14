package conversation

import (
	"context"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
)

type recognizerFunc func(context.Context, []byte, string) (string, error)

func (f recognizerFunc) Recognize(c context.Context, b []byte, l string) (string, error) {
	return f(c, b, l)
}

const testSession = "00112233-4455-4677-8899-aabbccddeeff"

func setup(t *testing.T, r Recognizer) misttv1.Mistt_ConversationClient {
	t.Helper()
	listener := bufconn.Listen(65536)
	svc, err := NewServer(Config{Token: strings.Repeat("t", 32), Model: "test-receipt"}, r)
	if err != nil {
		t.Fatal(err)
	}
	server := grpc.NewServer()
	misttv1.RegisterMisttServer(server, svc)
	go func() {
		if err := server.Serve(listener); err != nil && !errors.Is(err, grpc.ErrServerStopped) {
			t.Errorf("serve: %v", err)
		}
	}()
	t.Cleanup(server.Stop)
	conn, err := grpc.NewClient("passthrough:///buf", grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithContextDialer(func(context.Context, string) (net.Conn, error) { return listener.Dial() }))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := conn.Close(); err != nil {
			t.Error(err)
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	t.Cleanup(cancel)
	stream, err := misttv1.NewMisttClient(conn).Conversation(metadata.AppendToOutgoingContext(ctx, "authorization", "Bearer "+strings.Repeat("t", 32)))
	if err != nil {
		t.Fatal(err)
	}
	return stream
}
func sendStart(t *testing.T, s misttv1.Mistt_ConversationClient, mode misttv1.CaptureMode) {
	t.Helper()
	if err := s.Send(&misttv1.ConversationRequest{Payload: &misttv1.ConversationRequest_Start{Start: &misttv1.ConversationStart{SessionId: testSession, Language: "en", CaptureMode: mode}}}); err != nil {
		t.Fatal(err)
	}
}
func sendPCM(t *testing.T, s misttv1.Mistt_ConversationClient, sequence uint64) {
	t.Helper()
	if err := s.Send(&misttv1.ConversationRequest{Payload: &misttv1.ConversationRequest_Audio{Audio: &misttv1.MicrophonePCM{Sequence: sequence, Pcm16: make([]byte, 320)}}}); err != nil {
		t.Fatal(err)
	}
}
func checkpoint(t *testing.T, s misttv1.Mistt_ConversationClient) {
	t.Helper()
	if err := s.Send(&misttv1.ConversationRequest{Payload: &misttv1.ConversationRequest_Checkpoint{Checkpoint: &misttv1.RecognitionCheckpoint{ThroughSample: 160}}}); err != nil {
		t.Fatal(err)
	}
}
func TestFinalization(t *testing.T) {
	for _, text := range []string{"do not delete it", ""} {
		t.Run(text, func(t *testing.T) {
			t.Parallel()
			called := make(chan struct{})
			release := make(chan struct{})
			s := setup(t, recognizerFunc(func(ctx context.Context, b []byte, l string) (string, error) {
				if len(b) != 320 || l != "en" {
					t.Error("incorrect audio interval")
				}
				close(called)
				select {
				case <-release:
					return text, nil
				case <-ctx.Done():
					return "", ctx.Err()
				}
			}))
			sendStart(t, s, misttv1.CaptureMode_CAPTURE_MODE_MICROPHONE)
			if e, err := s.Recv(); err != nil || e.GetSessionStarted() == nil {
				t.Fatalf("admission %v %v", e, err)
			}
			sendPCM(t, s, 1)
			checkpoint(t, s)
			<-called
			close(release)
			if text != "" {
				e, err := s.Recv()
				if err != nil || e.GetTranscription().GetText() != text || !e.GetTranscription().GetIsFinal() {
					t.Fatalf("final %v %v", e, err)
				}
			}
			e, err := s.Recv()
			if err != nil || e.GetRecognitionProgress().GetFinalizedThroughSample() != 160 {
				t.Fatalf("coverage %v %v", e, err)
			}
		})
	}
}
func TestGapCannotAdvanceCoverage(t *testing.T) {
	s := setup(t, recognizerFunc(func(context.Context, []byte, string) (string, error) {
		t.Error("recognizer called across gap")
		return "", nil
	}))
	sendStart(t, s, misttv1.CaptureMode_CAPTURE_MODE_MICROPHONE)
	if _, err := s.Recv(); err != nil {
		t.Fatal(err)
	}
	sendPCM(t, s, 2)
	e, err := s.Recv()
	if err != nil || e.GetSessionGap() == nil {
		t.Fatalf("gap %v %v", e, err)
	}
	if _, err := s.Recv(); status.Code(err) != codes.DataLoss {
		t.Fatalf("terminal %v", err)
	}
}
func TestArmedCannotUpload(t *testing.T) {
	s := setup(t, recognizerFunc(func(context.Context, []byte, string) (string, error) {
		t.Error("armed audio reached recognition")
		return "", nil
	}))
	sendStart(t, s, misttv1.CaptureMode_CAPTURE_MODE_ARMED)
	if _, err := s.Recv(); status.Code(err) != codes.FailedPrecondition {
		t.Fatalf("armed admission %v", err)
	}
}
func TestRecognitionFailureHasNoCoverage(t *testing.T) {
	s := setup(t, recognizerFunc(func(context.Context, []byte, string) (string, error) { return "", errors.New("backend lost") }))
	sendStart(t, s, misttv1.CaptureMode_CAPTURE_MODE_MICROPHONE)
	if _, err := s.Recv(); err != nil {
		t.Fatal(err)
	}
	sendPCM(t, s, 1)
	checkpoint(t, s)
	if _, err := s.Recv(); status.Code(err) != codes.Unavailable {
		t.Fatalf("recognition failure %v", err)
	}
}

func TestResumedSpeechDeliveredWhileRecognitionPending(t *testing.T) {
	called := make(chan struct{})
	release := make(chan struct{})
	s := setup(t, recognizerFunc(func(ctx context.Context, _ []byte, _ string) (string, error) {
		close(called)
		select {
		case <-release:
			return "first clause", nil
		case <-ctx.Done():
			return "", ctx.Err()
		}
	}))
	sendStart(t, s, misttv1.CaptureMode_CAPTURE_MODE_MICROPHONE)
	if _, err := s.Recv(); err != nil {
		t.Fatal(err)
	}
	sendPCM(t, s, 1)
	checkpoint(t, s)
	<-called
	// The old synchronous implementation deadlocked here until inference ended.
	if err := s.Send(&misttv1.ConversationRequest{Payload: &misttv1.ConversationRequest_Activity{Activity: &misttv1.ConversationActivity{Speaking: true, CaptureSample: 160}}}); err != nil {
		t.Fatal(err)
	}
	event, err := s.Recv()
	if err != nil || event.GetSpeechStarted() == nil {
		t.Fatalf("resumption blocked by recognition: %v %v", event, err)
	}
	close(release)
	if _, err := s.Recv(); err != nil {
		t.Fatal(err)
	}
	if event, err := s.Recv(); err != nil || event.GetRecognitionProgress() == nil {
		t.Fatalf("coverage after resumption: %v %v", event, err)
	}
}
