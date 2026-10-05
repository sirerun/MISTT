package config

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDefaultsAreBoundedAndMatchAppHelperContract(t *testing.T) {
	cfg := Defaults()
	if cfg.Listen != "127.0.0.1:50051" || cfg.Language != "en" || cfg.StartupTimeout != 180*time.Second || cfg.DrainTimeout != 5*time.Second {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
	if len(cfg.IncludeHelperExecutables) != 1 || cfg.IncludeHelperExecutables[0] != ApprovedHelperExecutable {
		t.Fatalf("default helper contract mismatch: %+v", cfg.IncludeHelperExecutables)
	}
	if err := cfg.Validate(false); err != nil {
		t.Fatal(err)
	}
}

func TestOnlyLoopbackAndApprovedHelperAreAccepted(t *testing.T) {
	cases := map[string]func(*Config){
		"public listener":         func(c *Config) { c.Listen = "0.0.0.0:50051" },
		"remote listener":         func(c *Config) { c.Listen = "192.0.2.1:50051" },
		"unsupported language":    func(c *Config) { c.Language = "fr" },
		"unknown helper":          func(c *Config) { c.IncludeHelperExecutables = []string{"/tmp/MediaSDK_Server"} },
		"missing approved helper": func(c *Config) { c.IncludeHelperExecutables = nil },
		"excessive queue":         func(c *Config) { c.FrameQueue = 4097 },
		"negative duration":       func(c *Config) { c.MaxDuration = -time.Second },
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			cfg := Defaults()
			mutate(&cfg)
			if err := cfg.Validate(false); err == nil {
				t.Fatal("accepted invalid configuration")
			}
		})
	}
}

func TestHelperEnvironmentAcceptsOnlyApprovedRelativePath(t *testing.T) {
	t.Setenv("MISTT_HELPER_EXECUTABLES", ApprovedHelperExecutable)
	cfg, err := FromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if len(cfg.IncludeHelperExecutables) != 1 || cfg.IncludeHelperExecutables[0] != ApprovedHelperExecutable {
		t.Fatalf("wrong helper list: %+v", cfg.IncludeHelperExecutables)
	}
	if err := cfg.Validate(false); err != nil {
		t.Fatalf("approved environment override did not validate: %v", err)
	}
	t.Setenv("MISTT_HELPER_EXECUTABLES", ApprovedHelperExecutable+","+ApprovedHelperExecutable)
	duplicate, err := FromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if err := duplicate.Validate(false); err == nil {
		t.Fatal("accepted duplicate approved helper paths")
	}
	t.Setenv("MISTT_HELPER_EXECUTABLES", "/Applications/App.app/Contents/Resources/app/electron/sdk/lib/MediaSDK_Server")
	if _, err := FromEnv(); err == nil {
		t.Fatal("accepted absolute helper path")
	}
}

func TestRunFlagsCanCompleteEnvironmentConfigurationBeforeValidation(t *testing.T) {
	for _, key := range []string{"MISTT_DGX_ENDPOINT", "MISTT_TOKEN_FILE"} {
		t.Setenv(key, "")
	}
	cfg, err := FromEnv()
	if err != nil {
		t.Fatal(err)
	}
	token := filepath.Join(t.TempDir(), "token")
	if err := os.WriteFile(token, []byte("test-token"), 0600); err != nil {
		t.Fatal(err)
	}
	// run applies parsed flag values after FromEnv and validates the final config.
	cfg.Endpoint = "wss://gateway.example.test/v1"
	cfg.TokenFile = token
	if err := cfg.Validate(true); err != nil {
		t.Fatalf("flag-completed config did not validate: %v", err)
	}
}

func TestTokenPathMustBeRestrictedRegularNonsymlink(t *testing.T) {
	dir := t.TempDir()
	token := filepath.Join(dir, "token")
	if err := os.WriteFile(token, []byte("test-token"), 0600); err != nil {
		t.Fatal(err)
	}
	cfg := Defaults()
	cfg.TokenFile = token
	if err := cfg.Validate(false); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(token, 0644); err != nil {
		t.Fatal(err)
	}
	if err := cfg.Validate(false); err == nil {
		t.Fatal("accepted broad token permissions")
	}
	link := filepath.Join(dir, "token-link")
	if err := os.Symlink(token, link); err != nil {
		t.Fatal(err)
	}
	cfg.TokenFile = link
	if err := cfg.Validate(false); err == nil {
		t.Fatal("accepted symlink token path")
	}
}
