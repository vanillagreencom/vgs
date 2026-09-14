package recovery

import (
	"bytes"
	"log/slog"
	"strings"
	"testing"
)

func TestRunContainsAPanicAndLogsWhereItHappened(t *testing.T) {
	var out bytes.Buffer
	log := slog.New(slog.NewTextHandler(&out, nil))
	after := false

	Run(log, "unit.under.test", func() { panic("boom") })
	after = true

	if !after {
		t.Fatal("Run let the panic unwind its caller")
	}
	for _, want := range []string{"where=unit.under.test", "panic=boom", "stack="} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("log %q lacks %q", out.String(), want)
		}
	}
}

func TestRunLogsNothingForAUnitThatReturns(t *testing.T) {
	var out bytes.Buffer
	ran := false

	Run(slog.New(slog.NewTextHandler(&out, nil)), "unit.under.test", func() { ran = true })

	if !ran || out.Len() != 0 {
		t.Fatalf("ran = %v, log = %q; want the unit run and nothing logged", ran, out.String())
	}
}
