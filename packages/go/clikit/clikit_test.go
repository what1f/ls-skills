package clikit

import (
	"bytes"
	"encoding/json"
	"errors"
	"testing"
)

func TestFailJSON(t *testing.T) {
	var out, errOut bytes.Buffer
	code := Fail(&out, &errOut, FormatJSON, Usagef("bad %s", "flag"))
	if code != ExitUsage {
		t.Fatalf("exit = %d", code)
	}
	var got struct {
		OK    bool  `json:"ok"`
		Error Error `json:"error"`
	}
	if err := json.Unmarshal(out.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	if got.OK || got.Error.Code != "usage" || got.Error.Message != "bad flag" {
		t.Fatalf("unexpected %s", out.String())
	}
}

func TestFailPlainError(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := Fail(&out, &errOut, FormatText, errors.New("boom")); code != ExitFailure {
		t.Fatalf("exit = %d", code)
	}
	if errOut.String() != "error: boom\n" || out.Len() != 0 {
		t.Fatalf("stdout=%q stderr=%q", out.String(), errOut.String())
	}
}

func TestRunVersion(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := RunVersion("x", []string{"--format", "json"}, &out, &errOut); code != ExitOK {
		t.Fatalf("exit = %d, stderr = %s", code, errOut.String())
	}
	var got struct {
		OK   bool      `json:"ok"`
		Data BuildInfo `json:"data"`
	}
	if err := json.Unmarshal(out.Bytes(), &got); err != nil || !got.OK || got.Data.Name != "x" || got.Data.Version != "dev" {
		t.Fatalf("unexpected %s (%v)", out.String(), err)
	}
}

func TestFlagSetErrors(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := RunVersion("x", []string{"--format", "yaml"}, &out, &errOut); code != ExitUsage {
		t.Fatalf("bad format exit = %d", code)
	}
	out.Reset()
	if code := RunVersion("x", []string{"--bogus", "--format=json"}, &out, &errOut); code != ExitUsage || !bytes.Contains(out.Bytes(), []byte(`"ok":false`)) {
		t.Fatalf("unknown flag exit = %d out = %s", code, out.String())
	}
	out.Reset()
	if code := RunVersion("x", []string{"--help"}, &out, &errOut); code != ExitOK || !bytes.Contains(out.Bytes(), []byte("Usage:")) {
		t.Fatalf("help exit = %d out = %s", code, out.String())
	}
}
