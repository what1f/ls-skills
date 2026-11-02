package repo

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

const distDir = "dist"

// HostPlatform is the platform of the running machine, e.g. darwin-arm64.
func HostPlatform() string { return runtime.GOOS + "-" + runtime.GOARCH }

// Stamp is the build metadata injected into binaries.
type Stamp struct {
	Version string
	Commit  string
	Date    string
}

// BinaryName is the release asset name of a tool for a platform.
func BinaryName(tool, platform string) string {
	name := tool + "-" + platform
	if strings.HasPrefix(platform, "windows-") {
		name += ".exe"
	}
	return name
}

// GitStamp reads commit and commit date of HEAD. A dirty tree marks the commit.
func GitStamp(root, version string) Stamp {
	s := Stamp{Version: version}
	if out, err := gitOutput(root, "rev-parse", "--short=12", "HEAD"); err == nil {
		s.Commit = out
		if date, err := gitOutput(root, "log", "-1", "--format=%cI"); err == nil {
			s.Date = date
		}
		if status, err := gitOutput(root, "status", "--porcelain"); err == nil && status != "" {
			s.Commit += "-dirty"
		}
	}
	return s
}

func gitOutput(root string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = root
	out, err := cmd.Output()
	return strings.TrimSpace(string(out)), err
}

// Build cross-compiles a tool for the given platforms into dist/<tool>/,
// verifies the host binary if it was built, and rewrites checksums.txt.
func (r *Repo) Build(t *Tool, platforms []string, stamp Stamp, log io.Writer) error {
	out := filepath.Join(r.Root, distDir, t.Name)
	if err := os.MkdirAll(out, 0o755); err != nil {
		return err
	}
	for _, pl := range platforms {
		if !contains(t.Platforms, pl) {
			return fmt.Errorf("%s does not list platform %s in tool.yaml", t.Name, pl)
		}
		dst := filepath.Join(out, BinaryName(t.Name, pl))
		fmt.Fprintf(log, "build %s %s %s\n", t.Name, stamp.Version, pl)
		var err error
		switch t.Lang {
		case "go":
			err = r.buildGo(t, pl, stamp, dst)
		case "zig":
			err = r.buildZig(t, pl, stamp, dst)
		default:
			err = fmt.Errorf("unknown lang %q", t.Lang)
		}
		if err != nil {
			return fmt.Errorf("build %s %s: %w", t.Name, pl, err)
		}
		if pl == HostPlatform() {
			if err := VerifyBinary(dst, t.Name, stamp.Version); err != nil {
				return err
			}
			fmt.Fprintf(log, "verified %s\n", filepath.Base(dst))
		}
	}
	return writeChecksums(out)
}

func (r *Repo) buildGo(t *Tool, platform string, s Stamp, dst string) error {
	goos, goarch, _ := strings.Cut(platform, "-")
	pkg := "github.com/what1f/ls-skills/packages/go/clikit"
	ldflags := fmt.Sprintf("-s -w -X %[1]s.version=%[2]s -X %[1]s.commit=%[3]s -X %[1]s.date=%[4]s", pkg, s.Version, s.Commit, s.Date)
	cmd := exec.Command("go", "build", "-trimpath", "-ldflags", ldflags, "-o", dst, "./"+filepath.ToSlash(filepath.Join(t.Dir, "cli")))
	cmd.Dir = r.Root
	cmd.Env = append(os.Environ(), "CGO_ENABLED=0", "GOOS="+goos, "GOARCH="+goarch)
	return run(cmd)
}

var zigTargets = map[string]string{
	"darwin-amd64":  "x86_64-macos",
	"darwin-arm64":  "aarch64-macos",
	"linux-amd64":   "x86_64-linux-musl",
	"linux-arm64":   "aarch64-linux-musl",
	"windows-amd64": "x86_64-windows-gnu",
	"windows-arm64": "aarch64-windows-gnu",
}

func (r *Repo) buildZig(t *Tool, platform string, s Stamp, dst string) error {
	prefix, err := os.MkdirTemp("", "zig-out-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(prefix)
	cmd := exec.Command("zig", "build",
		"-Dtarget="+zigTargets[platform], "-Doptimize=ReleaseSafe", "-Dstrip=true",
		"-Dversion="+s.Version, "-Dcommit="+s.Commit, "-Ddate="+s.Date,
		"--prefix", prefix)
	cmd.Dir = filepath.Join(r.Root, t.Dir, "cli")
	if err := run(cmd); err != nil {
		return err
	}
	bin := t.Name
	if strings.HasPrefix(platform, "windows-") {
		bin += ".exe"
	}
	return copyFile(filepath.Join(prefix, "bin", bin), dst)
}

// VerifyBinary runs `<bin> version --format json` and checks name and version.
func VerifyBinary(bin, name, version string) error {
	out, err := exec.Command(bin, "version", "--format", "json").Output()
	if err != nil {
		return fmt.Errorf("%s version: %w", bin, err)
	}
	var got struct {
		OK   bool `json:"ok"`
		Data struct {
			Name    string `json:"name"`
			Version string `json:"version"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &got); err != nil {
		return fmt.Errorf("%s version --format json: %v: %s", bin, err, out)
	}
	if !got.OK || got.Data.Name != name || got.Data.Version != version {
		return fmt.Errorf("%s version reports %s %s, want %s %s", bin, got.Data.Name, got.Data.Version, name, version)
	}
	if text, err := exec.Command(bin, "--version").Output(); err != nil || !bytes.Contains(text, []byte(version)) {
		return fmt.Errorf("%s --version: want output containing %s, got %q (%v)", bin, version, text, err)
	}
	return nil
}

// Smoke verifies prebuilt host binaries in dist/ (used on native CI runners).
func (r *Repo) Smoke(log io.Writer) error {
	found := 0
	for _, t := range r.Tools {
		bin := filepath.Join(r.Root, distDir, t.Name, BinaryName(t.Name, HostPlatform()))
		if !exists(bin) {
			continue
		}
		_ = os.Chmod(bin, 0o755)
		if err := VerifyBinary(bin, t.Name, t.Version); err != nil {
			return err
		}
		fmt.Fprintf(log, "verified %s\n", filepath.Base(bin))
		found++
	}
	if found == 0 {
		return fmt.Errorf("no %s binaries found in %s/", HostPlatform(), distDir)
	}
	return nil
}

func writeChecksums(dir string) error {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	var lines []string
	for _, e := range entries {
		if e.IsDir() || e.Name() == "checksums.txt" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		lines = append(lines, hex.EncodeToString(sum[:])+"  "+e.Name())
	}
	sort.Strings(lines)
	return os.WriteFile(filepath.Join(dir, "checksums.txt"), []byte(strings.Join(lines, "\n")+"\n"), 0o644)
}

func copyFile(src, dst string) error {
	data, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	return os.WriteFile(dst, data, 0o755)
}

func run(cmd *exec.Cmd) error {
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}
