package service

import (
	"errors"
	"github.com/sirerun/MISTT/internal/audio"
	"github.com/sirerun/MISTT/internal/backend"
	"math"
	"time"
)

const budgetRotationReason = "budget_rotation"
const rotationLimitReason = "rotation_limit"

// budgetCaptureWindow starts BEFORE dispatching capture_start, rather than at
// the latest processed audio frame. Queued native PCM is already inside that
// capture interval; it must not be mistaken for new post-timer audio.
func budgetCaptureWindow(ready backend.Ready, headroom, drain time.Duration) (time.Duration, error) {
	if headroom < drain+2*time.Second || headroom > time.Minute {
		return 0, errors.New("rotation headroom must reserve drain timeout plus2s and be <=1m")
	}
	if len(ready.SourceSampleCaps) != 2 {
		return 0, errors.New("rotation requires both admitted source sample caps")
	}
	min := uint64(math.MaxUint64)
	for _, source := range []audio.Source{audio.Microphone, audio.CallAudio} {
		cap := ready.SourceSampleCaps[source]
		if cap == 0 {
			return 0, errors.New("rotation source budget missing")
		}
		if cap < min {
			min = cap
		}
	}
	seconds := min / uint64(audio.SampleRate)
	remainder := min % uint64(audio.SampleRate)
	if seconds > uint64(math.MaxInt64/int64(time.Second)) {
		return 0, errors.New("rotation source budget overflows duration")
	}
	base := time.Duration(seconds) * time.Second
	tail := time.Duration(remainder) * time.Second / time.Duration(audio.SampleRate)
	if tail > time.Duration(math.MaxInt64)-base {
		return 0, errors.New("rotation source budget overflows duration")
	}
	duration := base + tail
	if duration <= headroom+time.Second {
		return 0, errors.New("source budget too small for bounded rotation headroom")
	}
	return duration - headroom, nil
}

// Must hold s.mu. This is a total operator-consent budget, never reset by rotation.
func (s *Service) rotationOverallExpiredLocked(now time.Time) bool {
	return s.cfg.BudgetRotation && s.cfg.MaxDuration > 0 && !s.budgetStarted.IsZero() && !now.Before(s.budgetStarted.Add(s.cfg.MaxDuration))
}
func (s *Service) rotatePair(pair *activePair) {
	s.mu.Lock()
	if s.active != pair || pair.stopping {
		s.mu.Unlock()
		return
	}
	reason := budgetRotationReason
	if s.rotationOverallExpiredLocked(time.Now()) {
		s.muted = true
		s.reason = "max_duration"
		reason = "max_duration"
	} else if s.budgetRotations >= s.cfg.MaxBudgetRotations {
		s.muted = true
		s.reason = rotationLimitReason
		reason = rotationLimitReason
	}
	s.publishLocked()
	s.signalLocked()
	s.mu.Unlock()
	if reason == budgetRotationReason && s.cfg.ContinuousRollover {
		if next := s.rolloverPair(pair); next != nil {
			go s.runPair(next)
		}
		return
	}
	// No retry/unmute: only a fully settled nil-cause stop can leave consent intact.
	s.stopPair(pair, reason, nil)
}
