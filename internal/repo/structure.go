package repo

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

const versionMarker = "x-release-please-version"

const maxSkillBodyLines = 500

var (
	zonVersionRe    = regexp.MustCompile(`(?m)^\s*\.version\s*=\s*"([^"]*)"(.*)$`)
	zonMinZigRe     = regexp.MustCompile(`(?m)^\s*\.minimum_zig_version\s*=\s*"([^"]*)"`)
	mdLinkRe        = regexp.MustCompile(`\]\(([^)\s]+)(?:\s+"[^"]*")?\)`)
	inlineCodeRe    = regexp.MustCompile("`[^`]*`")
	yamlVersionLine = regexp.MustCompile(`(?m)^\s*version:.*$`)
)

// Structure checks every repo rule and returns all violations.
func Structure(root string) []string {
	r, problems := Load(root)
	add := func(format string, a ...any) { problems = append(problems, fmt.Sprintf(format, a...)) }

	// Root files.
	checkAgentsLink(root, ".", true, add)
	zigVersion := strings.TrimSpace(readString(filepath.Join(root, ".zig-version")))
	if zigVersion == "" {
		add(".zig-version: missing or empty")
	}

	// Tools.
	skillOwners := map[string]string{}
	for _, t := range r.Tools {
		dir := filepath.Base(t.Dir)
		p := t.Dir + "/tool.yaml"
		if t.schema != 1 {
			add("%s: schema must be 1", p)
		}
		if t.Name != dir {
			add("%s: name %q must equal directory name %q", p, t.Name, dir)
		}
		if !nameRe.MatchString(t.Name) {
			add("%s: name %q must be kebab-case", p, t.Name)
		}
		if !semverRe.MatchString(t.Version) {
			add("%s: version %q must be X.Y.Z", p, t.Version)
		}
		checkMarker(root, p, yamlVersionLine, add)
		if !t.skillDeclared {
			add("%s: declare `skill: <name>` or `skill: null`", p)
		} else if t.Skill != "" {
			if r.Skill(t.Skill) == nil {
				add("%s: skill %q has no skills/%s directory", p, t.Skill, t.Skill)
			}
			if other, dup := skillOwners[t.Skill]; dup {
				add("%s: skill %q already paired with tool %q", p, t.Skill, other)
			}
			skillOwners[t.Skill] = t.Name
		}
		if len(t.Platforms) == 0 {
			add("%s: platforms must not be empty", p)
		}
		for _, pl := range t.Platforms {
			if !slices.Contains(Platforms, pl) {
				add("%s: unsupported platform %q (supported: %s)", p, pl, strings.Join(Platforms, ", "))
			}
		}
		if !exists(filepath.Join(root, t.Dir, "CHANGELOG.md")) {
			add("%s/CHANGELOG.md: missing", t.Dir)
		}
		if !exists(filepath.Join(root, t.Dir, "README.md")) {
			add("%s/README.md: missing", t.Dir)
		}
		checkAgentsLink(root, t.Dir, false, add)

		cli := filepath.Join(t.Dir, "cli")
		switch t.Lang {
		case "go":
			if !exists(filepath.Join(root, cli, "main.go")) {
				add("%s/main.go: missing (Go tools build ./%s)", cli, cli)
			}
		case "zig":
			checkZig(root, t, zigVersion, add)
		default:
			add("%s: lang %q must be go or zig", p, t.Lang)
		}
	}

	// Skills.
	for _, s := range r.Skills {
		dir := filepath.Base(s.Dir)
		p := s.Dir + "/SKILL.md"
		if s.Name != dir {
			add("%s: name %q must equal directory name %q", p, s.Name, dir)
		}
		if !nameRe.MatchString(s.Name) {
			add("%s: name %q must be kebab-case", p, s.Name)
		}
		if s.Description == "" {
			add("%s: description is required", p)
		}
		if !semverRe.MatchString(s.Version) {
			add("%s: metadata.version %q must be X.Y.Z", p, s.Version)
		}
		checkMarker(root, p, yamlVersionLine, add)
		if s.Requires != "" {
			tool, _, ok := parseRequires(s.Requires)
			if !ok {
				add("%s: metadata.requires %q must look like <tool>>=X.Y.Z", p, s.Requires)
			} else if _, err := r.Tool(tool); err != nil {
				add("%s: metadata.requires names unknown tool %q", p, tool)
			}
		}
		if owner, ok := skillOwners[s.Name]; ok && s.Requires == "" {
			add("%s: paired with tool %q, so metadata.requires is required", p, owner)
		}
		if s.BodyLines > maxSkillBodyLines {
			add("%s: body has %d lines, move branch-only content to references/ (limit %d)", p, s.BodyLines, maxSkillBodyLines)
		}
		if !exists(filepath.Join(root, s.Dir, "CHANGELOG.md")) {
			add("%s/CHANGELOG.md: missing", s.Dir)
		}
		checkLinks(root, s.Dir, add)
	}

	// Forbidden files inside products and shared packages.
	for _, top := range []string{"tools", "skills", "packages"} {
		_ = filepath.WalkDir(filepath.Join(root, top), func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			rel, _ := filepath.Rel(root, path)
			switch d.Name() {
			case ".zig-cache", "zig-out":
				return filepath.SkipDir
			case ".git":
				add("%s: nested git repository", rel)
				return filepath.SkipDir
			case "go.mod", "go.sum", "go.work":
				add("%s: only the root go.mod is allowed", rel)
			}
			return nil
		})
	}

	// Generated files.
	if len(problems) == 0 {
		stale, err := r.Sync(true)
		if err != nil {
			add("sync: %v", err)
		}
		for _, f := range stale {
			add("%s: out of date, run `make sync`", f)
		}
	}
	return problems
}

// checkAgentsLink enforces CLAUDE.md -> AGENTS.md symlinks.
func checkAgentsLink(root, dir string, required bool, add func(string, ...any)) {
	agents := filepath.Join(root, dir, "AGENTS.md")
	claude := filepath.Join(root, dir, "CLAUDE.md")
	rel := filepath.Join(dir, "CLAUDE.md")
	if !exists(agents) {
		if required {
			add("%s: missing", filepath.Join(dir, "AGENTS.md"))
		}
		if exists(claude) {
			add("%s: exists without AGENTS.md", rel)
		}
		return
	}
	target, err := os.Readlink(claude)
	if err != nil || target != "AGENTS.md" {
		add("%s: must be a symlink to AGENTS.md (ln -s AGENTS.md %s)", rel, rel)
	}
}

// checkMarker makes sure release-please can bump the version line.
func checkMarker(root, rel string, line *regexp.Regexp, add func(string, ...any)) {
	m := line.FindString(readString(filepath.Join(root, rel)))
	if !strings.Contains(m, versionMarker) {
		add("%s: version line needs a `# %s` comment so releases can bump it", rel, versionMarker)
	}
}

func checkZig(root string, t *Tool, zigVersion string, add func(string, ...any)) {
	cli := filepath.Join(t.Dir, "cli")
	for _, f := range []string{"build.zig", "build.zig.zon"} {
		if !exists(filepath.Join(root, cli, f)) {
			add("%s/%s: missing", cli, f)
		}
	}
	zonPath := filepath.Join(cli, "build.zig.zon")
	zon := readString(filepath.Join(root, zonPath))
	if m := zonVersionRe.FindStringSubmatch(zon); m == nil {
		add("%s: .version missing", zonPath)
	} else {
		if m[1] != t.Version {
			add("%s: .version %q must equal tool.yaml version %q", zonPath, m[1], t.Version)
		}
		if !strings.Contains(m[2], versionMarker) {
			add("%s: .version line needs a `// %s` comment", zonPath, versionMarker)
		}
	}
	if m := zonMinZigRe.FindStringSubmatch(zon); m == nil || m[1] != zigVersion {
		add("%s: .minimum_zig_version must equal .zig-version (%s)", zonPath, zigVersion)
	}
	if exists(filepath.Join(root, cli, "build.zig.zon.lock")) {
		add("%s: lock files are not allowed", cli)
	}
}

// checkLinks verifies relative Markdown links in every .md file of a skill.
func checkLinks(root, dir string, add func(string, ...any)) {
	_ = filepath.WalkDir(filepath.Join(root, dir), func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || filepath.Ext(path) != ".md" || d.Name() == "CHANGELOG.md" {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		inFence := false
		for i, line := range strings.Split(readString(path), "\n") {
			if strings.HasPrefix(strings.TrimSpace(line), "```") {
				inFence = !inFence
				continue
			}
			if inFence {
				continue
			}
			line = inlineCodeRe.ReplaceAllString(line, "")
			for _, m := range mdLinkRe.FindAllStringSubmatch(line, -1) {
				target := m[1]
				if strings.Contains(target, "://") || strings.HasPrefix(target, "#") || strings.HasPrefix(target, "mailto:") {
					continue
				}
				target, _, _ = strings.Cut(target, "#")
				if !exists(filepath.Join(filepath.Dir(path), target)) {
					add("%s:%d: broken link %s", rel, i+1, m[1])
				}
			}
		}
		return nil
	})
}

func readString(path string) string {
	b, _ := os.ReadFile(path)
	return string(b)
}
