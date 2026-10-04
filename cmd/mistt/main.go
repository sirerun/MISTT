package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"syscall"

	"github.com/sirerun/MISTT/internal/backend/dgx"
	"github.com/sirerun/MISTT/internal/config"
	"github.com/sirerun/MISTT/internal/ipc"
	"github.com/sirerun/MISTT/internal/service"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
func run(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: mistt run|status|transcribe|mute|unmute")
	}
	switch args[0] {
	case "run":
		return runDaemon(args[1:])
	case "status":
		return runStatus(args[1:])
	case "transcribe":
		return runTranscribe(args[1:])
	case "mute":
		return runMute(args[1:], true)
	case "unmute":
		return runMute(args[1:], false)
	default:
		return fmt.Errorf("unknown command %q", args[0])
	}
}
func runDaemon(args []string) error {
	cfg, err := config.FromEnv()
	if err != nil {
		return err
	}
	flags := flag.NewFlagSet("run", flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	flags.StringVar(&cfg.Listen, "listen", cfg.Listen, "loopback gRPC address")
	flags.StringVar(&cfg.Endpoint, "dgx-endpoint", cfg.Endpoint, "authenticated wss DGX endpoint")
	flags.StringVar(&cfg.TokenFile, "token-file", cfg.TokenFile, "restricted DGX bearer-token file")
	flags.StringVar(&cfg.CAFile, "ca-file", cfg.CAFile, "optional custom DGX CA bundle")
	flags.StringVar(&cfg.Language, "language", cfg.Language, "paired recognition language")
	flags.StringVar(&cfg.MicrophoneDevice, "microphone-device", cfg.MicrophoneDevice, "native microphone selection")
	flags.StringVar(&cfg.TargetBundleID, "target-bundle-id", cfg.TargetBundleID, "selected app bundle identity")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() != 0 {
		return errors.New("run does not accept positional arguments")
	}
	if err := cfg.Validate(true); err != nil {
		return err
	}
	info, err := os.Stdin.Stat()
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeCharDevice != 0 {
		return errors.New("run requires native owner IPC on stdin; standalone device capture is unsupported")
	}
	provider, err := dgx.New(dgx.Config{Endpoint: cfg.Endpoint, TokenFile: cfg.TokenFile, CAFile: cfg.CAFile, QueueCap: cfg.FrameQueue, DrainTimeout: cfg.DrainTimeout})
	if err != nil {
		return err
	}
	listener, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return fmt.Errorf("listen for loopback gRPC: %w", err)
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	out := ipc.NewWriter(os.Stdout, cfg.NativeControlQueue)
	svc := service.New(cfg, provider, os.Stdin, out)
	return svc.Run(ctx, listener)
}
