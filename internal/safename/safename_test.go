package safename

import (
	"strings"
	"testing"
	"unicode/utf8"
)

func TestSanitize(t *testing.T) {
	tests := []struct {
		in   string
		want string
	}{
		{"photo.jpg", "photo.jpg"},
		{"../../etc/passwd", "passwd"},
		{`C:\Users\me\report.pdf`, "report.pdf"},
		{"..", ""},
		{".", ""},
		{"", ""},
		{"\x00evil.txt", "evil.txt"},
		{"a\nb\tc.txt", "a_b_c.txt"},
		{"  spaced.txt  ", "spaced.txt"},
		{"name. ", "name"},
		{"data\\..\\secret", "secret"},
		{"normal name (1).txt", "normal name (1).txt"},
	}
	for _, tc := range tests {
		if got := Sanitize(tc.in); got != tc.want {
			t.Errorf("Sanitize(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestSanitizeByteLimit(t *testing.T) {
	long := strings.Repeat("a", 500)
	got := Sanitize(long)
	if len(got) != MaxNameBytes {
		t.Fatalf("length = %d, want %d", len(got), MaxNameBytes)
	}
	unicodeName := strings.Repeat("é", 150)
	got = Sanitize(unicodeName)
	if len(got) > MaxNameBytes {
		t.Fatalf("unicode name length = %d, want <= %d", len(got), MaxNameBytes)
	}
	if !utf8.ValidString(got) {
		t.Fatalf("Sanitize returned invalid UTF-8: %q", got)
	}
}

func TestUnique(t *testing.T) {
	used := map[string]bool{"a.txt": true, "a-1.txt": true}
	if got := Unique("a.txt", used); got != "a-2.txt" {
		t.Fatalf("Unique = %q, want a-2.txt", got)
	}
	if got := Unique("new.txt", used); got != "new.txt" {
		t.Fatalf("Unique = %q, want new.txt", got)
	}
}

func TestJobDirRejectsTraversal(t *testing.T) {
	if _, err := JobDir("/data", "../etc"); err == nil {
		t.Fatal("expected traversal job id to be rejected")
	}
	got, err := JobDir("/data", "0123456789abcdef0123456789abcdef")
	if err != nil {
		t.Fatal(err)
	}
	if got != "/data/jobs/0123456789abcdef0123456789abcdef" {
		t.Fatalf("JobDir = %q", got)
	}
}

func TestReserved(t *testing.T) {
	for _, name := range []string{"ferry", "SHA256SUMS", "MD5SUMS", "FERRY-MANIFEST.json", "README-FERRY.txt", "../ferry"} {
		if !Reserved(name) {
			t.Errorf("Reserved(%q) = false, want true", name)
		}
	}
	for _, name := range []string{"photo.jpg", "ferry.txt", "sha256sums"} {
		if Reserved(name) {
			t.Errorf("Reserved(%q) = true, want false", name)
		}
	}
}
