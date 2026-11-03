// Package repo implements the repo maintenance tool: structure checks,
// generated-file sync, cross builds and scaffolding.
package repo

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// GitHub repository that hosts releases. Keep in sync with install.sh/ps1.
const GitHubRepo = "what1f/ls-skills"

// Platforms is the full supported build matrix.
var Platforms = []string{
	"darwin-amd64", "darwin-arm64",
	"linux-amd64", "linux-arm64",
	"windows-amd64", "windows-arm64",
}

var (
	nameRe   = regexp.MustCompile(`^[a-z][a-z0-9]*(-[a-z0-9]+)*$`)
	semverRe = regexp.MustCompile(`^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$`)
)

// Repo is a loaded view of the repository.
type Repo struct {
	Root   string
	Tools  []*Tool
	Skills []*Skill
}

// Tool is tools/<name>/tool.yaml.
type Tool struct {
	Name      string
	Dir       string // relative, e.g. tools/foo
	Lang      string
	Version   string
	Skill     string // "" when the tool has no skill
	Platforms []string

	skillDeclared bool
	schema        int
}

// Skill is skills/<name>/SKILL.md.
type Skill struct {
	Name        string
	Dir         string // relative, e.g. skills/foo
	Description string
	Version     string
	Requires    string // e.g. "foo>=0.2.0"
	BodyLines   int
}

type toolFile struct {
	Schema    int      `yaml:"schema"`
	Name      string   `yaml:"name"`
	Lang      string   `yaml:"lang"`
	Version   string   `yaml:"version"`
	Skill     *string  `yaml:"skill"`
	Platforms []string `yaml:"platforms"`
}

type skillFrontmatter struct {
	Name        string            `yaml:"name"`
	Description string            `yaml:"description"`
	Metadata    map[string]string `yaml:"metadata"`
}

// FindRoot walks up from the working directory to the directory holding go.mod
// and tools/.
func FindRoot() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if exists(filepath.Join(dir, "go.mod")) && exists(filepath.Join(dir, ".release-please-manifest.json")) {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", errors.New("repo root not found (run inside the ls-skills checkout)")
		}
		dir = parent
	}
}

// Load reads every tool and skill. Parse errors are returned as problems so
// the structure check can report them all at once.
func Load(root string) (*Repo, []string) {
	r := &Repo{Root: root}
	var problems []string
	for _, name := range subdirs(filepath.Join(root, "tools")) {
		t, err := loadTool(root, name)
		if err != nil {
			problems = append(problems, err.Error())
			continue
		}
		r.Tools = append(r.Tools, t)
	}
	for _, name := range subdirs(filepath.Join(root, "skills")) {
		s, err := loadSkill(root, name)
		if err != nil {
			problems = append(problems, err.Error())
			continue
		}
		r.Skills = append(r.Skills, s)
	}
	return r, problems
}

func loadTool(root, name string) (*Tool, error) {
	dir := filepath.Join("tools", name)
	path := filepath.Join(dir, "tool.yaml")
	data, err := os.ReadFile(filepath.Join(root, path))
	if err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	var f toolFile
	if err := yaml.Unmarshal(data, &f); err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	var keys map[string]any
	_ = yaml.Unmarshal(data, &keys)
	_, declared := keys["skill"]
	t := &Tool{
		Name: f.Name, Dir: dir, Lang: f.Lang, Version: f.Version,
		Platforms: f.Platforms, skillDeclared: declared, schema: f.Schema,
	}
	if f.Skill != nil {
		t.Skill = *f.Skill
	}
	if t.Name == "" {
		t.Name = name
	}
	return t, nil
}

func loadSkill(root, name string) (*Skill, error) {
	dir := filepath.Join("skills", name)
	path := filepath.Join(dir, "SKILL.md")
	data, err := os.ReadFile(filepath.Join(root, path))
	if err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	fm, body, err := splitFrontmatter(data)
	if err != nil {
		return nil, fmt.Errorf("%s: %v", path, err)
	}
	var f skillFrontmatter
	if err := yaml.Unmarshal(fm, &f); err != nil {
		return nil, fmt.Errorf("%s: frontmatter: %v", path, err)
	}
	return &Skill{
		Name: f.Name, Dir: dir, Description: strings.TrimSpace(f.Description),
		Version: f.Metadata["version"], Requires: f.Metadata["requires"],
		BodyLines: bytes.Count(body, []byte("\n")),
	}, nil
}

func splitFrontmatter(data []byte) (fm, body []byte, err error) {
	// Tolerate CRLF checkouts (Windows with core.autocrlf).
	s := strings.ReplaceAll(string(data), "\r\n", "\n")
	if !strings.HasPrefix(s, "---\n") {
		return nil, nil, errors.New("missing YAML frontmatter")
	}
	end := strings.Index(s[4:], "\n---\n")
	if end < 0 {
		return nil, nil, errors.New("unterminated YAML frontmatter")
	}
	return []byte(s[4 : 4+end]), []byte(s[4+end+5:]), nil
}

// Tool returns the tool with the given name.
func (r *Repo) Tool(name string) (*Tool, error) {
	for _, t := range r.Tools {
		if t.Name == name {
			return t, nil
		}
	}
	return nil, fmt.Errorf("unknown tool %q", name)
}

// Skill returns the skill with the given name, or nil.
func (r *Repo) Skill(name string) *Skill {
	for _, s := range r.Skills {
		if s.Name == name {
			return s
		}
	}
	return nil
}

func subdirs(dir string) []string {
	entries, _ := os.ReadDir(dir)
	var names []string
	for _, e := range entries {
		if e.IsDir() && !strings.HasPrefix(e.Name(), ".") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return names
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// parseRequires parses "tool>=X.Y.Z".
func parseRequires(s string) (tool, version string, ok bool) {
	tool, version, ok = strings.Cut(s, ">=")
	tool, version = strings.TrimSpace(tool), strings.TrimSpace(version)
	return tool, version, ok && nameRe.MatchString(tool) && semverRe.MatchString(version)
}
