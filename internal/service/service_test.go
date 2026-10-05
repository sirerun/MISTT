package service

import (
	"math"
	"testing"
)

func TestTranscriptWallClockUnixMS(t *testing.T) {
	cases := []struct {
		name      string
		epochMS   int64
		offsetNS  uint64
		wantMS    int64
		wantError bool
	}{
		{name: "sub-millisecond offset truncates", epochMS: 123, offsetNS: 999_999, wantMS: 123},
		{name: "millisecond offset", epochMS: 123, offsetNS: 2_000_000, wantMS: 125},
		{name: "addition reaches maximum", epochMS: math.MaxInt64 - 1, offsetNS: 1_000_000, wantMS: math.MaxInt64},
		{name: "addition overflows maximum", epochMS: math.MaxInt64, offsetNS: 1_000_000, wantError: true},
		{name: "maximum unsigned offset remains representable", epochMS: math.MinInt64, offsetNS: math.MaxUint64, wantMS: math.MinInt64 + int64(math.MaxUint64/uint64(1_000_000))},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := transcriptWallClockUnixMS(tc.epochMS, tc.offsetNS)
			if (err != nil) != tc.wantError {
				t.Fatalf("transcriptWallClockUnixMS() error = %v, wantError %v", err, tc.wantError)
			}
			if err == nil && got != tc.wantMS {
				t.Fatalf("transcriptWallClockUnixMS() = %d, want %d", got, tc.wantMS)
			}
		})
	}
}
