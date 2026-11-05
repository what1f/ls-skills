package repo

import (
	"reflect"
	"testing"
)

func TestPlan(t *testing.T) {
	tools := []*Tool{
		{Name: "a", Lang: "go", Version: "0.2.0"},
		{Name: "b", Lang: "zig", Version: "0.1.0"},
	}
	unchanged := func(t *Tool) string { return t.Version }
	bumpedA := func(t *Tool) string {
		if t.Name == "a" {
			return "0.1.0"
		}
		return t.Version
	}
	none := []string{}
	for _, c := range []struct {
		name    string
		changed []string
		base    func(*Tool) string
		want    CIPlan
	}{
		{"docs only", []string{"README.md", "tools/a/CHANGELOG.md", "skills/x/references/y.md"}, unchanged,
			CIPlan{Check: none, Build: none}},
		{"skill", []string{"skills/x/SKILL.md", ".claude-plugin/marketplace.json"}, unchanged,
			CIPlan{Structure: true, Check: none, Build: none}},
		{"one tool", []string{"tools/a/cli/main.go", "tools/a/README.md"}, unchanged,
			CIPlan{Structure: true, Check: []string{"a"}, Build: none}},
		{"zig package", []string{"packages/zig/clikit/src/root.zig"}, unchanged,
			CIPlan{Structure: true, Check: []string{"b"}, Build: none}},
		{"shared", []string{"internal/repo/build.go"}, unchanged,
			CIPlan{Structure: true, CheckAll: true, Check: []string{"a", "b"}, Build: none}},
		{"workflow", []string{".github/workflows/ci.yml"}, unchanged,
			CIPlan{Structure: true, CheckAll: true, Check: []string{"a", "b"}, Build: none}},
		{"release", []string{"tools/a/tool.yaml", "tools/a/CHANGELOG.md"}, bumpedA,
			CIPlan{Structure: true, Check: []string{"a"}, Build: []string{"a"}}},
		{"new tool", []string{"tools/b/tool.yaml"}, func(t *Tool) string {
			if t.Name == "b" {
				return ""
			}
			return t.Version
		}, CIPlan{Structure: true, Check: []string{"b"}, Build: []string{"b"}}},
	} {
		if got := Plan(c.changed, tools, c.base); !reflect.DeepEqual(got, c.want) {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}
