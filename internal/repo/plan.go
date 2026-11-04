package repo

import (
	"fmt"
	"path"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// CIPlan lists the CI jobs a change needs.
type CIPlan struct {
	Structure bool     `json:"structure"` // any change besides docs
	CheckAll  bool     `json:"check_all"` // shared code or tooling changed
	Check     []string `json:"check"`     // tools to check
	Build     []string `json:"build"`     // tools whose version changed: cross-compile and smoke
}

// Paths that affect every tool: the repo tool, the Go module, Zig version,
// Makefile and workflows.
var sharedPaths = []string{"cmd/", "internal/", "go.mod", "go.sum", ".zig-version", "Makefile", ".github/workflows/"}

func isDoc(p string) bool {
	base := path.Base(p)
	if base == "SKILL.md" {
		return false
	}
	return strings.HasSuffix(base, ".md") || base == "LICENSE"
}

// Plan maps changed paths to CI jobs. baseVersion returns a tool's version
// before the change, or "" when the tool is new.
func Plan(changed []string, tools []*Tool, baseVersion func(*Tool) string) CIPlan {
	p := CIPlan{Check: []string{}, Build: []string{}}
	check := map[string]bool{}
	byName := map[string]*Tool{}
	for _, t := range tools {
		byName[t.Name] = t
	}
	for _, f := range changed {
		if isDoc(f) {
			continue
		}
		p.Structure = true
		switch {
		case strings.HasPrefix(f, "tools/"):
			name, _, _ := strings.Cut(strings.TrimPrefix(f, "tools/"), "/")
			if _, ok := byName[name]; ok {
				check[name] = true
			}
		case strings.HasPrefix(f, "packages/go/"), strings.HasPrefix(f, "packages/zig/"):
			lang := "go"
			if strings.HasPrefix(f, "packages/zig/") {
				lang = "zig"
			}
			for _, t := range tools {
				if t.Lang == lang {
					check[t.Name] = true
				}
			}
		default:
			for _, s := range sharedPaths {
				if f == s || (strings.HasSuffix(s, "/") && strings.HasPrefix(f, s)) {
					p.CheckAll = true
				}
			}
		}
	}
	for _, t := range tools {
		if p.CheckAll || check[t.Name] {
			p.Check = append(p.Check, t.Name)
		}
		if baseVersion(t) != t.Version {
			p.Build = append(p.Build, t.Name)
		}
	}
	sort.Strings(p.Check)
	sort.Strings(p.Build)
	return p
}

// PlanSince plans CI for the changes between base and HEAD.
func (r *Repo) PlanSince(base string) (CIPlan, error) {
	out, err := gitOutput(r.Root, "diff", "--name-only", base, "HEAD")
	if err != nil {
		return CIPlan{}, fmt.Errorf("git diff %s: %w", base, err)
	}
	var changed []string
	for _, line := range strings.Split(out, "\n") {
		if line != "" {
			changed = append(changed, line)
		}
	}
	return Plan(changed, r.Tools, func(t *Tool) string {
		data, err := gitOutput(r.Root, "show", base+":"+t.Dir+"/tool.yaml")
		if err != nil {
			return ""
		}
		var f toolFile
		if yaml.Unmarshal([]byte(data), &f) != nil {
			return ""
		}
		return f.Version
	}), nil
}
