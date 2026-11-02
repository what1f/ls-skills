package repo

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Generated files kept in sync with tools/ and skills/.
const (
	releaseConfigPath = "release-please-config.json"
	manifestPath      = ".release-please-manifest.json"
	marketplacePath   = ".claude-plugin/marketplace.json"
)

type extraFile struct {
	Type     string `json:"type"`
	Path     string `json:"path"`
	JSONPath string `json:"jsonpath,omitempty"`
}

type releasePackage struct {
	Component  string      `json:"component"`
	ExtraFiles []extraFile `json:"extra-files"`
}

type releaseConfig struct {
	Schema                string                    `json:"$schema"`
	ReleaseType           string                    `json:"release-type"`
	InitialVersion        string                    `json:"initial-version"`
	BumpMinorPreMajor     bool                      `json:"bump-minor-pre-major"`
	SeparatePullRequests  bool                      `json:"separate-pull-requests"`
	IncludeComponentInTag bool                      `json:"include-component-in-tag"`
	Packages              map[string]releasePackage `json:"packages"`
}

type marketplace struct {
	Name    string            `json:"name"`
	Owner   map[string]string `json:"owner"`
	Plugins []plugin          `json:"plugins"`
}

type plugin struct {
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Version     string   `json:"version"`
	Source      string   `json:"source"`
	Strict      bool     `json:"strict"`
	Skills      []string `json:"skills"`
}

// SkillComponent is the release-please component (and tag prefix) of a skill.
func SkillComponent(name string) string { return name + "-skill" }

// TagFor is the release tag of a tool version.
func TagFor(tool, version string) string { return tool + "-v" + version }

// generated renders every generated file from the current tools and skills.
func (r *Repo) generated() (map[string][]byte, error) {
	cfg := releaseConfig{
		Schema:                "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
		ReleaseType:           "go", // only writes CHANGELOG.md; versions go through extra-files
		InitialVersion:        "0.1.0",
		BumpMinorPreMajor:     true,
		SeparatePullRequests:  true,
		IncludeComponentInTag: true,
		Packages:              map[string]releasePackage{},
	}
	manifest := map[string]string{}
	for _, t := range r.Tools {
		files := []extraFile{{Type: "generic", Path: "tool.yaml"}}
		if t.Lang == "zig" {
			files = append(files, extraFile{Type: "generic", Path: "cli/build.zig.zon"})
		}
		cfg.Packages[t.Dir] = releasePackage{Component: t.Name, ExtraFiles: files}
		manifest[t.Dir] = t.Version
	}

	market := marketplace{Name: "ls-skills", Owner: map[string]string{"name": strings.Split(GitHubRepo, "/")[0]}, Plugins: []plugin{}}
	for _, s := range r.Skills {
		cfg.Packages[s.Dir] = releasePackage{
			Component: SkillComponent(s.Name),
			ExtraFiles: []extraFile{
				{Type: "generic", Path: "SKILL.md"},
				{Type: "json", Path: "/" + marketplacePath, JSONPath: fmt.Sprintf("$.plugins[?(@.name=='%s')].version", s.Name)},
			},
		}
		manifest[s.Dir] = s.Version
		market.Plugins = append(market.Plugins, plugin{
			Name: s.Name, Description: firstSentence(s.Description), Version: s.Version,
			Source: "./", Strict: false, Skills: []string{"./" + filepath.ToSlash(s.Dir)},
		})
	}

	out := map[string][]byte{}
	for path, v := range map[string]any{releaseConfigPath: cfg, manifestPath: manifest, marketplacePath: market} {
		b, err := marshal(v)
		if err != nil {
			return nil, err
		}
		out[path] = b
	}
	return out, nil
}

// Sync writes generated files. With check, it only reports stale files.
func (r *Repo) Sync(check bool) ([]string, error) {
	files, err := r.generated()
	if err != nil {
		return nil, err
	}
	var stale []string
	for _, path := range []string{releaseConfigPath, manifestPath, marketplacePath} {
		full := filepath.Join(r.Root, path)
		cur, _ := os.ReadFile(full)
		if bytes.Equal(cur, files[path]) {
			continue
		}
		stale = append(stale, path)
		if check {
			continue
		}
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			return nil, err
		}
		if err := os.WriteFile(full, files[path], 0o644); err != nil {
			return nil, err
		}
	}
	return stale, nil
}

func marshal(v any) ([]byte, error) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	if err := enc.Encode(v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func firstSentence(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	for _, sep := range []string{"。", ". "} {
		if i := strings.Index(s, sep); i > 0 {
			return s[:i+len(strings.TrimSpace(sep))]
		}
	}
	return s
}
