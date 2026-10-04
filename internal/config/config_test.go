package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func validConfig(t *testing.T) (string, string) {
	t.Helper()
	dir := t.TempDir()
	token := filepath.Join(dir, "token")
	if err := os.WriteFile(token, []byte("fixture-token\n"), 0600); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "config.yaml")
	body := `listen: "127.0.0.1:50051"
session:
  startup_timeout: 180s
  drain_timeout: 5s
  max_duration: 0s
capture:
  device: default
  sample_rate: 16000
  channels: 1
  format: s16le
stt:
  backend: dgx_vibevoice
  endpoint: https://dgx.example.invalid/mistt
  token_file: ` + token + `
  language: en
hub:
  client_buffer: 64
  audio_buffer_duration: 1s
log:
  level: info
`
	if err := os.WriteFile(path, []byte(body), 0600); err != nil {
		t.Fatal(err)
	}
	return path, token
}

func TestLoadYAMLThenEnvironmentThenFlags(t *testing.T) {
	path, _ := validConfig(t)
	c, err := Load(path, []string{"MISTT_LISTEN=127.0.0.1:51000", "MISTT_SESSION_STARTUP_TIMEOUT=90s"}, map[string]string{"listen": "[::1]:52000"})
	if err != nil {
		t.Fatal(err)
	}
	if c.Listen != "[::1]:52000" {
		t.Fatalf("flag did not override environment: %q", c.Listen)
	}
	if c.Session.StartupTimeout != durationValue(90_000_000_000) {
		t.Fatalf("environment duration not applied: %s", c.Session.StartupTimeout)
	}
}

func TestLoadRejectsUnsafeAndUnknownConfiguration(t *testing.T) {
	cases := []struct{ name, replace string }{
		{"wildcard listener", `listen: "0.0.0.0:50051"`},
		{"hostname listener", `listen: "localhost:50051"`},
		{"unsupported sample rate", `sample_rate: 44100`},
		{"retired grace", `grace: 1s`},
		{"unknown key", `surprise: true`},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path, _ := validConfig(t)
			b, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var changed string
			switch tc.name {
			case "wildcard listener", "hostname listener":
				changed = strings.Replace(string(b), `listen: "127.0.0.1:50051"`, tc.replace, 1)
			case "unsupported sample rate":
				changed = strings.Replace(string(b), "sample_rate: 16000", tc.replace, 1)
			case "retired grace":
				changed = strings.Replace(string(b), "  max_duration: 0s", "  max_duration: 0s\n  "+tc.replace, 1)
			case "unknown key":
				changed = string(b) + tc.replace + "\n"
			}
			if err := os.WriteFile(path, []byte(changed), 0600); err != nil {
				t.Fatal(err)
			}
			if _, err := Load(path, nil, nil); err == nil {
				t.Fatal("expected invalid configuration to fail")
			}
		})
	}
}

func TestLoadRejectsBroadTokenPermissions(t *testing.T) {
	path, token := validConfig(t)
	if err := os.Chmod(token, 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(path, nil, nil); err == nil {
		t.Fatal("expected broad token permissions to fail")
	}
}
