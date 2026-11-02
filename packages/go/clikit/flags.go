package clikit

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"strings"
)

// FlagSet is a subcommand flag set with the shared --format flag and
// contract-compliant help and usage errors.
type FlagSet struct {
	*flag.FlagSet
	format  *string
	summary string
	usage   string
}

// NewFlagSet creates flags for `<tool> <cmd>`. usage is the argument
// synopsis shown after the command, e.g. "[flags] <id>".
func NewFlagSet(tool, cmd, summary, usage string) *FlagSet {
	fs := flag.NewFlagSet(tool+" "+cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	return &FlagSet{
		FlagSet: fs,
		format:  fs.String("format", "text", "output format: text or json"),
		summary: summary,
		usage:   tool + " " + cmd + " " + usage,
	}
}

// Parse parses args. When done is true the command must return code
// immediately: help was printed (0) or the arguments were invalid (2).
func (f *FlagSet) Parse(args []string, stdout, stderr io.Writer) (format Format, code int, done bool) {
	err := f.FlagSet.Parse(args)
	if errors.Is(err, flag.ErrHelp) {
		f.PrintHelp(stdout)
		return FormatText, ExitOK, true
	}
	format, ferr := ParseFormat(*f.format)
	if ferr != nil {
		return FormatText, Fail(stdout, stderr, FormatText, ferr), true
	}
	if err != nil {
		return format, Fail(stdout, stderr, scanFormat(args), Usagef("%v (see --help)", err)), true
	}
	return format, ExitOK, false
}

// scanFormat finds --format in raw args, so errors raised before flag
// parsing finishes still honour --format json.
func scanFormat(args []string) Format {
	for i, a := range args {
		v, ok := strings.CutPrefix(strings.TrimPrefix(a, "-"), "-format")
		switch {
		case ok && v == "" && i+1 < len(args):
			v = args[i+1]
		case ok && strings.HasPrefix(v, "="):
			v = v[1:]
		default:
			continue
		}
		if f, err := ParseFormat(v); err == nil {
			return f
		}
	}
	return FormatText
}

// PrintHelp writes the command help.
func (f *FlagSet) PrintHelp(w io.Writer) {
	fmt.Fprintf(w, "%s\n\nUsage:\n  %s\n\nFlags:\n", f.summary, strings.TrimSpace(f.usage))
	f.SetOutput(w)
	f.PrintDefaults()
	f.SetOutput(io.Discard)
}

// RunVersion implements the `version` command every tool must expose.
func RunVersion(tool string, args []string, stdout, stderr io.Writer) int {
	fs := NewFlagSet(tool, "version", "Print version information.", "[flags]")
	format, code, done := fs.Parse(args, stdout, stderr)
	if done {
		return code
	}
	if fs.NArg() > 0 {
		return Fail(stdout, stderr, format, Usagef("version takes no arguments"))
	}
	info := Build(tool)
	if format == FormatJSON {
		_ = WriteOK(stdout, info)
	} else {
		fmt.Fprintln(stdout, info)
	}
	return ExitOK
}
