package repo

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Check runs structure, lint, tests and a host build with version
// verification. With tool set, only that tool (plus shared code) is checked.
// It never touches the network beyond fetching declared dependencies.
func (r *Repo) Check(tool string, log io.Writer) error {
	step := func(name string) { fmt.Fprintf(log, "==> %s\n", name) }

	step("structure")
	if problems := Structure(r.Root); len(problems) > 0 {
		return errors.New("structure:\n  " + strings.Join(problems, "\n  "))
	}

	tools := r.Tools
	if tool != "" {
		t, err := r.Tool(tool)
		if err != nil {
			return err
		}
		tools = []*Tool{t}
	}

	step("go fmt/vet/test")
	cmd := exec.Command("gofmt", "-l", ".")
	cmd.Dir = r.Root
	out, err := cmd.Output()
	if err != nil {
		return fmt.Errorf("gofmt: %w", err)
	}
	if s := strings.TrimSpace(string(out)); s != "" {
		return fmt.Errorf("gofmt: unformatted files (run gofmt -w):\n%s", s)
	}
	pkgs := []string{"./..."}
	if tool != "" {
		pkgs = []string{"./cmd/...", "./internal/...", "./packages/go/..."}
		if tools[0].Lang == "go" {
			pkgs = append(pkgs, "./"+tools[0].Dir+"/...")
		}
	}
	for _, args := range [][]string{append([]string{"vet"}, pkgs...), append([]string{"test"}, pkgs...)} {
		if err := r.runIn(r.Root, "go", args...); err != nil {
			return err
		}
	}

	zigDirs := zigPackageDirs(r.Root)
	for _, t := range tools {
		if t.Lang == "zig" {
			zigDirs = append(zigDirs, filepath.Join(r.Root, t.Dir, "cli"))
		}
	}
	if len(zigDirs) > 0 {
		step("zig fmt/test")
		for _, dir := range zigDirs {
			if err := r.runIn(dir, "zig", "fmt", "--check", "build.zig", "build.zig.zon", "src"); err != nil {
				return err
			}
			if err := r.runIn(dir, "zig", "build", "test"); err != nil {
				return err
			}
		}
	}

	step("host build + version")
	for _, t := range tools {
		if !contains(t.Platforms, HostPlatform()) {
			continue
		}
		if err := r.Build(t, []string{HostPlatform()}, GitStamp(r.Root, t.Version), log); err != nil {
			return err
		}
	}
	return nil
}

func zigPackageDirs(root string) []string {
	var dirs []string
	for _, name := range subdirs(filepath.Join(root, "packages", "zig")) {
		dirs = append(dirs, filepath.Join(root, "packages", "zig", name))
	}
	return dirs
}

func (r *Repo) runIn(dir, name string, args ...string) error {
	cmd := exec.Command(name, args...)
	cmd.Dir = dir
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		rel, _ := filepath.Rel(r.Root, dir)
		return fmt.Errorf("%s %s (in %s): %w", name, strings.Join(args, " "), rel, err)
	}
	return nil
}
