package repo

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestZigFingerprintMatchesZigChecksum(t *testing.T) {
	// `zig init` in a directory named hello_zig produced 0x1c1a4686xxxxxxxx.
	if fp := zigFingerprint("hello_zig"); !strings.HasPrefix(fp, "0x1c1a4686") {
		t.Fatalf("fingerprint %s has wrong name checksum", fp)
	}
}

func TestParseRequires(t *testing.T) {
	for in, ok := range map[string]bool{
		"foo>=1.2.3": true, "foo-bar >= 0.1.0": true,
		"foo>1.2.3": false, "foo>=1.2": false, "Foo>=1.0.0": false,
	} {
		if _, _, got := parseRequires(in); got != ok {
			t.Errorf("parseRequires(%q) = %v, want %v", in, got, ok)
		}
	}
}

func TestFirstSentence(t *testing.T) {
	if got := firstSentence("查询工单。当用户提到 TT 时使用。"); got != "查询工单。" {
		t.Fatalf("got %q", got)
	}
	if got := firstSentence("Greets people. Use when asked."); got != "Greets people." {
		t.Fatalf("got %q", got)
	}
}

func TestCheckLinks(t *testing.T) {
	root := t.TempDir()
	dir := filepath.Join(root, "skills", "x")
	_ = os.MkdirAll(filepath.Join(dir, "references"), 0o755)
	_ = os.WriteFile(filepath.Join(dir, "references", "ok.md"), nil, 0o644)
	body := "[ok](references/ok.md) [web](https://x.dev) [anchor](#a)\n" +
		"`[code](nope.md)`\n```\n[fenced](nope.md)\n```\n[bad](references/missing.md)\n"
	_ = os.WriteFile(filepath.Join(dir, "SKILL.md"), []byte(body), 0o644)

	var problems []string
	checkLinks(root, "skills/x", func(f string, a ...any) { problems = append(problems, f) })
	if len(problems) != 1 {
		t.Fatalf("want exactly the broken link reported, got %d", len(problems))
	}
}

func TestRepoStructure(t *testing.T) {
	root, err := filepath.Abs("../..")
	if err != nil {
		t.Fatal(err)
	}
	if problems := Structure(root); len(problems) > 0 {
		t.Fatalf("structure:\n%s", strings.Join(problems, "\n"))
	}
}

func TestSplitFrontmatterCRLF(t *testing.T) {
	fm, body, err := splitFrontmatter([]byte("---\r\nname: x\r\n---\r\nbody\r\n"))
	if err != nil || string(fm) != "name: x" || string(body) != "body\n" {
		t.Fatalf("got %q %q %v", fm, body, err)
	}
}
