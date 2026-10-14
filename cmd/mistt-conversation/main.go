// mistt-conversation exposes the additive authenticated microphone RPC locally.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/sirerun/MISTT/conversation"
	misttv1 "github.com/sirerun/MISTT/gen/mistt/v1"
	"google.golang.org/grpc"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func tokenFile(path string) (string, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return "", fmt.Errorf("stat token: %w", err)
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
		return "", errors.New("credential must be a regular nonsymlink file restricted to owner")
	}
	f, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("open token: %w", err)
	}
	defer f.Close()
	opened, err := f.Stat()
	if err != nil {
		return "", fmt.Errorf("stat open token: %w", err)
	}
	if !os.SameFile(info, opened) || opened.Mode().Perm()&0077 != 0 {
		return "", errors.New("credential file changed during open")
	}
	data, err := io.ReadAll(io.LimitReader(f, 4097))
	if err != nil {
		return "", fmt.Errorf("read token: %w", err)
	}
	token := strings.TrimSpace(string(data))
	if len(token) < 32 || len(token) > 4096 || strings.ContainsAny(token, "\r\n") {
		return "", errors.New("invalid token length or line breaks")
	}
	return token, nil
}
func run() error {
	address := flag.String("listen", "127.0.0.1:8792", "loopback gRPC address")
	endpoint := flag.String("recognizer", "", "explicit HTTPS Spark recognizer URL (or loopback HTTP)")
	tokenPath := flag.String("token-file", "", "restricted microphone RPC token file")
	backendTokenPath := flag.String("recognizer-token-file", "", "restricted local recognizer token file")
	model := flag.String("model", "", "exact locally prepared model identity/revision")
	flag.Parse()
	host, _, err := net.SplitHostPort(*address)
	if err != nil {
		return fmt.Errorf("listen address: %w", err)
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return errors.New("microphone RPC listener must be a loopback IP")
	}
	token, err := tokenFile(*tokenPath)
	if err != nil {
		return err
	}
	backendToken, err := tokenFile(*backendTokenPath)
	if err != nil {
		return err
	}
	recognizer, err := conversation.NewHTTPRecognizer(*endpoint, backendToken, &http.Client{})
	if err != nil {
		return err
	}
	service, err := conversation.NewServer(conversation.Config{Token: token, Model: *model}, recognizer)
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", *address)
	if err != nil {
		return fmt.Errorf("listen: %w", err)
	}
	defer listener.Close()
	server := grpc.NewServer(grpc.MaxRecvMsgSize(16384), grpc.MaxSendMsgSize(1<<20))
	misttv1.RegisterMisttServer(server, service)
	ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer cancel()
	stopped := make(chan struct{})
	defer close(stopped)
	go func() {
		select {
		case <-stopped:
			return
		case <-ctx.Done():
		}
		done := make(chan struct{})
		go func() { server.GracefulStop(); close(done) }()
		timer := time.NewTimer(2 * time.Second)
		defer timer.Stop()
		select {
		case <-done:
		case <-timer.C:
			server.Stop()
		}
	}()
	if err := server.Serve(listener); err != nil && !errors.Is(err, grpc.ErrServerStopped) {
		return fmt.Errorf("serve microphone RPC: %w", err)
	}
	return nil
}
