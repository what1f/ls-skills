// Package clikit implements the CLI contract shared by every Go tool in this
// repo: build info, the version command, output envelopes and exit codes.
package clikit

import (
	"fmt"
	"runtime"
)

// Set at build time by `go run ./cmd/repo build` via -ldflags -X.
var (
	version = "dev"
	commit  = ""
	date    = ""
)

// BuildInfo describes the running binary.
type BuildInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
	Commit  string `json:"commit"`
	Date    string `json:"date"`
	OS      string `json:"os"`
	Arch    string `json:"arch"`
}

// Build returns the build info of the current binary.
func Build(name string) BuildInfo {
	return BuildInfo{
		Name:    name,
		Version: version,
		Commit:  commit,
		Date:    date,
		OS:      runtime.GOOS,
		Arch:    runtime.GOARCH,
	}
}

// String renders the one-line text form used by `version` and `--version`.
func (b BuildInfo) String() string {
	s := fmt.Sprintf("%s %s (%s/%s", b.Name, b.Version, b.OS, b.Arch)
	if b.Commit != "" {
		s += ", " + b.Commit
	}
	if b.Date != "" {
		s += ", " + b.Date
	}
	return s + ")"
}
