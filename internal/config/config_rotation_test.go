package config

import (
	"testing"
	"time"
)

func TestBudgetRotationConfigDefaultsAndBounds(t *testing.T) {
	c := Defaults()
	if c.BudgetRotation {
		t.Fatal("rotation enabled without operator opt-in")
	}
	c.BudgetRotation = true
	if err := c.Validate(false); err != nil {
		t.Fatal(err)
	}
	for _, n := range []uint32{0, 257} {
		c.MaxBudgetRotations = n
		if err := c.Validate(false); err == nil {
			t.Fatal("unbounded rotation count accepted")
		}
	}
	c.MaxBudgetRotations = 32
	for _, head := range []time.Duration{time.Second, 61 * time.Second} {
		c.RotationHeadroom = head
		if err := c.Validate(false); err == nil {
			t.Fatal("unsafe headroom accepted")
		}
	}
}
func TestBudgetRotationConfigExplicitEnvironment(t *testing.T) {
	t.Setenv("MISTT_BUDGET_ROTATION", "true")
	t.Setenv("MISTT_MAX_BUDGET_ROTATIONS", "3")
	t.Setenv("MISTT_ROTATION_HEADROOM", "11s")
	c, e := FromEnv()
	if e != nil || !c.BudgetRotation || c.MaxBudgetRotations != 3 || c.RotationHeadroom != 11*time.Second {
		t.Fatal(c, e)
	}
	t.Setenv("MISTT_BUDGET_ROTATION", "not-a-boolean")
	if _, e = FromEnv(); e == nil {
		t.Fatal("implicit opt-in accepted")
	}
}

func TestContinuousRolloverIsExplicitAndRequiresBudgetRotation(t *testing.T) {
	c := Defaults()
	if c.ContinuousRollover {
		t.Fatal("continuous capture enabled by default")
	}
	c.ContinuousRollover = true
	if err := c.Validate(false); err == nil {
		t.Fatal("continuous capture admitted without rotation bounds")
	}
	t.Setenv("MISTT_CONTINUOUS_ROLLOVER", "true")
	t.Setenv("MISTT_BUDGET_ROTATION", "true")
	c, err := FromEnv()
	if err != nil {
		t.Fatal(err)
	}
	if !c.ContinuousRollover || !c.BudgetRotation {
		t.Fatal("explicit opt in lost")
	}
}
