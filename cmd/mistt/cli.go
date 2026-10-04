package main

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/sirerun/MISTT/gen/mistt/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

func dial(address string) (*grpc.ClientConn, error) {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return nil, fmt.Errorf("gRPC address must be a literal loopback host and port: %w", err)
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return nil, errors.New("gRPC client only connects to a literal loopback address")
	}
	return grpc.NewClient(address, grpc.WithTransportCredentials(insecure.NewCredentials()))
}
func runStatus(args []string) error {
	f := flag.NewFlagSet("status", flag.ContinueOnError)
	address := f.String("address", "127.0.0.1:50051", "loopback relay address")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 {
		return errors.New("status takes no positional arguments")
	}
	conn, err := dial(*address)
	if err != nil {
		return err
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	stream, err := misttv1.NewMisttClient(conn).WatchStatus(ctx, &misttv1.WatchStatusRequest{})
	if err != nil {
		return err
	}
	status, err := stream.Recv()
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(status)
}
func runMute(args []string, muted bool) error {
	f := flag.NewFlagSet("mute", flag.ContinueOnError)
	address := f.String("address", "127.0.0.1:50051", "loopback relay address")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 {
		return errors.New("mute/unmute takes no positional arguments")
	}
	conn, err := dial(*address)
	if err != nil {
		return err
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	client := misttv1.NewMisttClient(conn)
	status, err := client.WatchStatus(ctx, &misttv1.WatchStatusRequest{})
	if err != nil {
		return err
	}
	current, err := status.Recv()
	if err != nil {
		return err
	}
	requestID, err := newRequestID()
	if err != nil {
		return err
	}
	next, err := client.SetMuted(ctx, &misttv1.SetMutedRequest{Muted: muted, ExpectedRevision: current.Revision, RequestId: requestID})
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(next)
}
func newRequestID() (string, error) {
	var id [16]byte
	if _, err := rand.Read(id[:]); err != nil {
		return "", fmt.Errorf("generate request ID: %w", err)
	}
	id[6] = (id[6] & 0x0f) | 0x40
	id[8] = (id[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", id[0:4], id[4:6], id[6:8], id[8:10], id[10:16]), nil
}
func runTranscribe(args []string) error {
	f := flag.NewFlagSet("transcribe", flag.ContinueOnError)
	address := f.String("address", "127.0.0.1:50051", "loopback relay address")
	language := f.String("language", "en", "transcript language")
	if err := f.Parse(args); err != nil {
		return err
	}
	if f.NArg() != 0 {
		return errors.New("transcribe takes no positional arguments")
	}
	conn, err := dial(*address)
	if err != nil {
		return err
	}
	defer conn.Close()
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	stream, err := misttv1.NewMisttClient(conn).StreamTranscription(ctx)
	if err != nil {
		return err
	}
	if err := stream.Send(&misttv1.ClientMessage{Kind: &misttv1.ClientMessage_Subscribe{Subscribe: &misttv1.Subscribe{Language: *language}}}); err != nil {
		return err
	}
	if err := stream.CloseSend(); err != nil {
		return err
	}
	enc := json.NewEncoder(os.Stdout)
	for {
		event, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if err := enc.Encode(event); err != nil {
			return err
		}
	}
}
