package clikit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

// Format is the value of the --format flag.
type Format string

const (
	FormatText Format = "text"
	FormatJSON Format = "json"
)

// ParseFormat validates a --format value.
func ParseFormat(s string) (Format, error) {
	switch Format(s) {
	case FormatText, FormatJSON:
		return Format(s), nil
	}
	return "", Usagef("invalid --format %q (want text or json)", s)
}

// Exit codes. Agents stop retrying on ExitNeedsHuman.
const (
	ExitOK         = 0
	ExitFailure    = 1
	ExitUsage      = 2
	ExitNeedsHuman = 3
	ExitCancelled  = 130
)

// Error is a failure with a stable machine-readable code.
type Error struct {
	Code      string `json:"code"`
	Message   string `json:"message"`
	Retryable bool   `json:"retryable"`
	Exit      int    `json:"-"`
}

func (e *Error) Error() string { return e.Message }

// Usagef reports invalid arguments (exit 2).
func Usagef(format string, a ...any) *Error {
	return &Error{Code: "usage", Message: fmt.Sprintf(format, a...), Exit: ExitUsage}
}

// WriteOK writes {"ok":true,"data":...} as a single JSON object.
func WriteOK(w io.Writer, data any) error {
	return writeJSON(w, struct {
		OK   bool `json:"ok"`
		Data any  `json:"data"`
	}{true, data})
}

// Fail reports err in the requested format and returns the exit code.
// JSON goes to stdout as a single object; text goes to stderr.
func Fail(stdout, stderr io.Writer, format Format, err error) int {
	var e *Error
	if errors.Is(err, context.Canceled) {
		e = &Error{Code: "cancelled", Message: "cancelled", Exit: ExitCancelled}
	} else if !errors.As(err, &e) {
		e = &Error{Code: "failure", Message: err.Error(), Exit: ExitFailure}
	}
	if format == FormatJSON {
		_ = writeJSON(stdout, struct {
			OK    bool   `json:"ok"`
			Error *Error `json:"error"`
		}{false, e})
	} else {
		fmt.Fprintln(stderr, "error:", e.Message)
	}
	return e.Exit
}

func writeJSON(w io.Writer, v any) error {
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	return enc.Encode(v)
}
