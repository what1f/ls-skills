package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestVersion(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"version", "--format", "json"}, &out, &errOut); code != 0 {
		t.Fatalf("exit = %d, stderr = %s", code, errOut.String())
	}
	if !strings.Contains(out.String(), `"name":"`+name+`"`) {
		t.Fatalf("unexpected output %s", out.String())
	}
}

func TestUnknownCommand(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"nope"}, &out, &errOut); code != 2 {
		t.Fatalf("exit = %d", code)
	}
}

func TestGreet(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"greet", "--name", "Ada", "--format", "json"}, &out, &errOut); code != 0 {
		t.Fatalf("exit = %d, stderr = %s", code, errOut.String())
	}
	if got, want := out.String(), `{"ok":true,"data":{"message":"Hello, Ada!"}}`+"\n"; got != want {
		t.Fatalf("got %s, want %s", got, want)
	}
}
