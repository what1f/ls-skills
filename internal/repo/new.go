package repo

import (
	"crypto/rand"
	"embed"
	"encoding/binary"
	"fmt"
	"hash/crc32"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"text/template"
)

//go:embed templates
var templates embed.FS

// NewOptions configures scaffolding.
type NewOptions struct {
	Name  string
	Lang  string // go, zig, or "" for a skill without a CLI
	Skill bool
}

type scaffoldData struct {
	Name, Ident, Lang, Repo, ZigVersion, Fingerprint string
	Tool, Skill                                      bool
	Platforms                                        []string
}

// New scaffolds tools/<name> and/or skills/<name>, then syncs generated files.
func (r *Repo) New(opts NewOptions) ([]string, error) {
	if !nameRe.MatchString(opts.Name) {
		return nil, fmt.Errorf("name %q must be kebab-case", opts.Name)
	}
	if opts.Lang != "" && opts.Lang != "go" && opts.Lang != "zig" {
		return nil, fmt.Errorf("--lang must be go, zig or none")
	}
	if opts.Lang == "" && !opts.Skill {
		return nil, fmt.Errorf("nothing to create")
	}
	ident := strings.ReplaceAll(opts.Name, "-", "_")
	data := scaffoldData{
		Name: opts.Name, Ident: ident, Lang: opts.Lang, Repo: GitHubRepo,
		ZigVersion:  strings.TrimSpace(readString(filepath.Join(r.Root, ".zig-version"))),
		Fingerprint: zigFingerprint(ident),
		Tool:        opts.Lang != "", Skill: opts.Skill, Platforms: Platforms,
	}

	type job struct{ src, dst string }
	var jobs []job
	if data.Tool {
		jobs = append(jobs, job{"templates/tool", filepath.Join("tools", opts.Name)})
		jobs = append(jobs, job{"templates/" + opts.Lang, filepath.Join("tools", opts.Name)})
	}
	if data.Skill {
		jobs = append(jobs, job{"templates/skill", filepath.Join("skills", opts.Name)})
	}
	for _, j := range jobs {
		if data.Tool && j.src == "templates/tool" && exists(filepath.Join(r.Root, j.dst)) {
			return nil, fmt.Errorf("%s already exists", j.dst)
		}
		if j.src == "templates/skill" && exists(filepath.Join(r.Root, j.dst)) {
			return nil, fmt.Errorf("%s already exists", j.dst)
		}
	}

	var created []string
	for _, j := range jobs {
		err := fs.WalkDir(templates, j.src, func(path string, d fs.DirEntry, err error) error {
			if err != nil || d.IsDir() {
				return err
			}
			rel := strings.TrimSuffix(strings.TrimPrefix(path, j.src+"/"), ".tmpl")
			dst := filepath.Join(r.Root, j.dst, rel)
			raw, err := templates.ReadFile(path)
			if err != nil {
				return err
			}
			tmpl, err := template.New(path).Delims("[[", "]]").Parse(string(raw))
			if err != nil {
				return err
			}
			if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
				return err
			}
			f, err := os.Create(dst)
			if err != nil {
				return err
			}
			defer f.Close()
			created = append(created, filepath.Join(j.dst, rel))
			return tmpl.Execute(f, data)
		})
		if err != nil {
			return created, err
		}
	}

	fresh, problems := Load(r.Root)
	if len(problems) > 0 {
		return created, fmt.Errorf("%s", strings.Join(problems, "\n"))
	}
	_, err := fresh.Sync(false)
	return created, err
}

// zigFingerprint builds a build.zig.zon fingerprint: random id in the low
// 32 bits, CRC32 of the package name in the high 32 bits.
func zigFingerprint(name string) string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	id := binary.LittleEndian.Uint32(b[:])
	if id == 0 || id == 0xffffffff {
		id = 1
	}
	return fmt.Sprintf("0x%016x", uint64(crc32.ChecksumIEEE([]byte(name)))<<32|uint64(id))
}
