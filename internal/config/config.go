package config

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Profiles select one exact executable; they never expand to system audio.
var targetExecutables = map[string][]string{
	"com.tiktok.livestudio.desktop":          {"Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"},
	"us.zoom.xos":                            {"Contents/MacOS/zoom.us", "Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost"},
	"run.david.evidence-copilot.development": {"Contents/MacOS/EvidenceOverlay"},
}

func ApprovedTarget(bundle, executable string) bool {
	for _, allowed := range targetExecutables[bundle] {
		if executable == allowed {
			return true
		}
	}
	return false
}

const ApprovedHelperExecutable = "Contents/Resources/app/electron/sdk/lib/MediaSDK_Server"

type Config struct {
	Listen                   string
	Endpoint                 string
	TokenFile                string
	CAFile                   string
	Language                 string
	MicrophoneDevice         string
	TargetBundleID           string
	IncludeHelperPIDs        []uint32
	IncludeHelperExecutables []string
	StartupTimeout           time.Duration
	DrainTimeout             time.Duration
	MaxDuration              time.Duration
	ClientBuffer             int
	FrameQueue               int
	NativeControlQueue       int
	BudgetRotation           bool
	MaxBudgetRotations       uint32
	RotationHeadroom         time.Duration
}

func Defaults() Config {
	return Config{Listen: "127.0.0.1:50051", Language: "en", MicrophoneDevice: "default", TargetBundleID: "com.tiktok.livestudio.desktop", IncludeHelperExecutables: []string{ApprovedHelperExecutable}, StartupTimeout: 180 * time.Second, DrainTimeout: 5 * time.Second, MaxDuration: 0, ClientBuffer: 64, FrameQueue: 160, NativeControlQueue: 32, MaxBudgetRotations: 32, RotationHeadroom: 10 * time.Second}
}
func FromEnv() (Config, error) {
	c := Defaults()
	set := func(name string, dst *string) {
		if v, ok := os.LookupEnv(name); ok {
			*dst = v
		}
	}
	set("MISTT_LISTEN", &c.Listen)
	set("MISTT_DGX_ENDPOINT", &c.Endpoint)
	set("MISTT_TOKEN_FILE", &c.TokenFile)
	set("MISTT_CA_FILE", &c.CAFile)
	set("MISTT_LANGUAGE", &c.Language)
	set("MISTT_MICROPHONE_DEVICE", &c.MicrophoneDevice)
	set("MISTT_TARGET_BUNDLE_ID", &c.TargetBundleID)
	if v, ok := os.LookupEnv("MISTT_HELPER_PIDS"); ok && strings.TrimSpace(v) != "" {
		for _, part := range strings.Split(v, ",") {
			n, err := strconv.ParseUint(strings.TrimSpace(part), 10, 32)
			if err != nil || n == 0 {
				return Config{}, fmt.Errorf("invalid MISTT_HELPER_PIDS value %q", part)
			}
			c.IncludeHelperPIDs = append(c.IncludeHelperPIDs, uint32(n))
		}
	}
	if v, ok := os.LookupEnv("MISTT_HELPER_EXECUTABLES"); ok && strings.TrimSpace(v) != "" {
		c.IncludeHelperExecutables = nil
		for _, p := range strings.Split(v, ",") {
			p = strings.TrimSpace(p)
			if !ApprovedTarget(c.TargetBundleID, p) {
				return Config{}, errors.New("MISTT_HELPER_EXECUTABLES permits only the approved app-relative helper")
			}
			c.IncludeHelperExecutables = append(c.IncludeHelperExecutables, p)
		}
	}
	for key, dst := range map[string]*time.Duration{"MISTT_STARTUP_TIMEOUT": &c.StartupTimeout, "MISTT_DRAIN_TIMEOUT": &c.DrainTimeout, "MISTT_MAX_DURATION": &c.MaxDuration, "MISTT_ROTATION_HEADROOM": &c.RotationHeadroom} {
		if value, ok := os.LookupEnv(key); ok {
			d, err := time.ParseDuration(value)
			if err != nil {
				return Config{}, fmt.Errorf("parse %s: %w", key, err)
			}
			*dst = d
		}
	}
	for key, dst := range map[string]*int{"MISTT_CLIENT_BUFFER": &c.ClientBuffer, "MISTT_FRAME_QUEUE": &c.FrameQueue} {
		if value, ok := os.LookupEnv(key); ok {
			n, err := strconv.Atoi(value)
			if err != nil {
				return Config{}, fmt.Errorf("parse %s: %w", key, err)
			}
			*dst = n
		}
	}

	if value, ok := os.LookupEnv("MISTT_BUDGET_ROTATION"); ok {
		v, e := strconv.ParseBool(value)
		if e != nil {
			return Config{}, fmt.Errorf("parse MISTT_BUDGET_ROTATION: %w", e)
		}
		c.BudgetRotation = v
	}
	if value, ok := os.LookupEnv("MISTT_MAX_BUDGET_ROTATIONS"); ok {
		v, e := strconv.ParseUint(value, 10, 32)
		if e != nil {
			return Config{}, fmt.Errorf("parse MISTT_MAX_BUDGET_ROTATIONS: %w", e)
		}
		c.MaxBudgetRotations = uint32(v)
	}
	return c, nil
}
func (c Config) Validate(requireCredentials bool) error {
	if c.BudgetRotation && (c.MaxBudgetRotations < 1 || c.MaxBudgetRotations > 256 || c.RotationHeadroom < c.DrainTimeout+2*time.Second || c.RotationHeadroom > time.Minute) {
		return errors.New("budget rotation requires1..256 rotations and drain+2s..1m headroom")
	}

	host, port, err := net.SplitHostPort(c.Listen)
	if err != nil {
		return fmt.Errorf("listen must be loopback host:port: %w", err)
	}
	ip := net.ParseIP(host)
	portNumber, portErr := strconv.Atoi(port)
	if ip == nil || !ip.IsLoopback() || (host != "127.0.0.1" && host != "::1") || portErr != nil || portNumber < 1 || portNumber > 65535 {
		return errors.New("gRPC must bind only literal 127.0.0.1 or [::1]")
	}
	if c.Language != "en" || c.MicrophoneDevice == "" || c.TargetBundleID == "" {
		return errors.New("paired gateway v1 requires English, a microphone device and target bundle ID")
	}
	if c.StartupTimeout <= 0 || c.DrainTimeout <= 0 || c.MaxDuration < 0 {
		return errors.New("startup/drain timeouts must be positive and max duration nonnegative")
	}
	if c.ClientBuffer < 1 || c.ClientBuffer > 4096 || c.FrameQueue < 1 || c.FrameQueue > 4096 || c.NativeControlQueue < 1 {
		return errors.New("buffer capacities must be positive and bounded")
	}
	if len(c.IncludeHelperPIDs) != 0 || len(c.IncludeHelperExecutables) != 1 || !ApprovedTarget(c.TargetBundleID, c.IncludeHelperExecutables[0]) || len(c.MicrophoneDevice) > 256 || len(c.TargetBundleID) > 255 {
		return errors.New("native target configuration exceeds bounded IPC limits")
	}
	if c.Endpoint != "" {
		u, err := url.Parse(c.Endpoint)
		if err != nil || u.Scheme != "wss" || u.Host == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
			return errors.New("DGX endpoint must be a credential-free wss URL")
		}
	} else if requireCredentials {
		return errors.New("MISTT_DGX_ENDPOINT must name the authenticated wss endpoint")
	}
	if c.TokenFile != "" {
		info, err := os.Lstat(c.TokenFile)
		if err != nil {
			return fmt.Errorf("stat restricted DGX token: %w", err)
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 {
			return errors.New("DGX token must be a regular file with permissions no broader than 0600")
		}
	} else if requireCredentials {
		return errors.New("MISTT_TOKEN_FILE is required")
	}
	if c.CAFile != "" {
		if !filepath.IsAbs(c.CAFile) {
			return errors.New("MISTT_CA_FILE must be absolute")
		}
		if _, err := os.Stat(c.CAFile); err != nil {
			return fmt.Errorf("stat custom DGX CA: %w", err)
		}
	}
	return nil
}
