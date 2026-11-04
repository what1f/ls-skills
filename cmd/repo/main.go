// Command repo maintains this repository: structure checks, generated-file
// sync, cross builds and scaffolding. Run `go run ./cmd/repo help`.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/what1f/ls-skills/internal/repo"
)

const usage = `repo - maintain the ls-skills monorepo.

Usage:
  go run ./cmd/repo <command> [flags]

Commands:
  structure                      Check repo rules and generated files
  sync                           Regenerate release-please config, manifest and marketplace.json
  check [--tool T]               structure + fmt + vet + tests + host build with version check
  build [--tool T] [--platform P | --all-platforms] [--tag T]
                                 Cross-compile into dist/<tool>/ with checksums.txt
  smoke                          Verify host binaries already in dist/
  plan --base REV                Print the CI jobs needed for changes since REV, as JSON
  new <name> --lang go|zig|none [--no-skill]
                                 Scaffold tools/<name> and/or skills/<name>
`

func main() {
	if err := run(os.Args[1:], os.Stdout, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, "error:", err)
		os.Exit(1)
	}
}

func run(args []string, stdout, stderr io.Writer) error {
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		fmt.Fprint(stdout, usage)
		return nil
	}
	root, err := repo.FindRoot()
	if err != nil {
		return err
	}
	cmd, rest := args[0], args[1:]
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(stderr)
	tool := fs.String("tool", "", "limit to one tool")
	platform := fs.String("platform", "", "target platform, e.g. linux-amd64 (default: host)")
	all := fs.Bool("all-platforms", false, "build every platform listed in tool.yaml")
	tag := fs.String("tag", "", "release tag; must equal <tool>-v<tool.yaml version>")
	lang := fs.String("lang", "", "go, zig or none")
	noSkill := fs.Bool("no-skill", false, "do not create a paired skill")
	base := fs.String("base", "", "git revision to diff against")

	var positional []string
	if cmd == "new" && len(rest) > 0 && !strings.HasPrefix(rest[0], "-") {
		positional, rest = rest[:1], rest[1:]
	}
	if err := fs.Parse(rest); err != nil {
		return err
	}

	if cmd == "structure" {
		problems := repo.Structure(root)
		if len(problems) > 0 {
			return fmt.Errorf("%d problem(s):\n  %s", len(problems), strings.Join(problems, "\n  "))
		}
		fmt.Fprintln(stdout, "structure ok")
		return nil
	}

	r, problems := repo.Load(root)
	if len(problems) > 0 && cmd != "new" {
		return fmt.Errorf("%s", strings.Join(problems, "\n"))
	}

	switch cmd {
	case "sync":
		changed, err := r.Sync(false)
		for _, f := range changed {
			fmt.Fprintln(stdout, "updated", f)
		}
		return err
	case "check":
		if err := r.Check(*tool, stderr); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "check ok")
		return nil
	case "build":
		return build(r, root, *tool, *platform, *all, *tag, stderr)
	case "smoke":
		return r.Smoke(stdout)
	case "plan":
		if *base == "" {
			return fmt.Errorf("usage: plan --base REV")
		}
		p, err := r.PlanSince(*base)
		if err != nil {
			return err
		}
		return json.NewEncoder(stdout).Encode(p)
	case "new":
		if len(positional) == 0 {
			return fmt.Errorf("usage: new <name> --lang go|zig|none [--no-skill]")
		}
		l := *lang
		switch l {
		case "none":
			l = ""
		case "":
			return fmt.Errorf("--lang is required (go, zig or none)")
		}
		created, err := r.New(repo.NewOptions{Name: positional[0], Lang: l, Skill: !*noSkill})
		for _, f := range created {
			fmt.Fprintln(stdout, "created", f)
		}
		return err
	}
	return fmt.Errorf("unknown command %q (run help)", cmd)
}

func build(r *repo.Repo, root, toolName, platform string, all bool, tag string, log io.Writer) error {
	tools := r.Tools
	if toolName != "" {
		t, err := r.Tool(toolName)
		if err != nil {
			return err
		}
		tools = []*repo.Tool{t}
	}
	if tag != "" && len(tools) != 1 {
		return fmt.Errorf("--tag needs --tool")
	}
	for _, t := range tools {
		if tag != "" && tag != repo.TagFor(t.Name, t.Version) {
			return fmt.Errorf("tag %s does not match tool.yaml (want %s)", tag, repo.TagFor(t.Name, t.Version))
		}
		platforms := []string{repo.HostPlatform()}
		switch {
		case all:
			platforms = t.Platforms
		case platform != "":
			platforms = []string{platform}
		}
		if err := r.Build(t, platforms, repo.GitStamp(root, t.Version), log); err != nil {
			return err
		}
	}
	return nil
}
