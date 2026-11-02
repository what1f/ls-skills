// Command hello-go is the Go example tool: it greets people.
package main

import (
	"fmt"
	"io"
	"os"

	"github.com/what1f/ls-skills/packages/go/clikit"
)

const name = "hello-go"

const usage = `hello-go - greet people (Go example tool).

Usage:
  hello-go <command> [flags]

Commands:
  greet     Print a greeting
  version   Print version information

Flags:
  -h, --help   Show help
  --version    Print version

Run 'hello-go <command> --help' for command flags.
`

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprint(stderr, usage)
		return clikit.ExitUsage
	}
	switch cmd, rest := args[0], args[1:]; cmd {
	case "-h", "--help", "help":
		fmt.Fprint(stdout, usage)
		return clikit.ExitOK
	case "--version":
		fmt.Fprintln(stdout, clikit.Build(name))
		return clikit.ExitOK
	case "version":
		return clikit.RunVersion(name, rest, stdout, stderr)
	case "greet":
		return greet(rest, stdout, stderr)
	default:
		fmt.Fprintf(stderr, "unknown command %q\n\n%s", cmd, usage)
		return clikit.ExitUsage
	}
}

func greet(args []string, stdout, stderr io.Writer) int {
	fs := clikit.NewFlagSet(name, "greet", "Print a greeting.", "[flags]")
	who := fs.String("name", "world", "who to greet")
	format, code, done := fs.Parse(args, stdout, stderr)
	if done {
		return code
	}
	if fs.NArg() > 0 {
		return clikit.Fail(stdout, stderr, format, clikit.Usagef("greet takes no arguments, use --name"))
	}
	message := "Hello, " + *who + "!"
	if format == clikit.FormatJSON {
		_ = clikit.WriteOK(stdout, map[string]string{"message": message})
		return clikit.ExitOK
	}
	fmt.Fprintln(stdout, message)
	return clikit.ExitOK
}
