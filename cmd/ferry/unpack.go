package main

import (
	"bufio"
	"compress/gzip"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/term"

	"ferry/internal/securefile"
)

// unpackOptions controls verification and unpacking of an extracted image
// directory. Both `ferry unpack` and `ferry download` use it.
type unpackOptions struct {
	Dir        string
	Passphrase string
	VerifyOnly bool
	Force      bool
}

// unpackCommand runs inside the extracted image directory. It verifies the
// checksum files, then decrypts .ferry files and decompresses .gz files.
func unpackCommand(args []string) error {
	fs := flag.NewFlagSet("unpack", flag.ContinueOnError)
	fs.SetOutput(os.Stderr)
	opts := unpackOptions{}
	fs.StringVar(&opts.Passphrase, "passphrase", "", "job passphrase (prompted when needed)")
	fs.StringVar(&opts.Dir, "dir", ".", "directory containing the extracted image files")
	fs.BoolVar(&opts.VerifyOnly, "verify-only", false, "only verify checksums, do not unpack")
	fs.BoolVar(&opts.Force, "force", false, "overwrite existing output files")
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return nil
		}
		return err
	}
	return runUnpack(opts)
}

func runUnpack(opts unpackOptions) error {
	entries, err := os.ReadDir(opts.Dir)
	if err != nil {
		return fmt.Errorf("read directory %s: %w", opts.Dir, err)
	}

	checksumFiles := 0
	verified := 0
	for _, name := range []string{"SHA256SUMS", "MD5SUMS"} {
		path := filepath.Join(opts.Dir, name)
		if _, err := os.Stat(path); err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return err
		}
		checksumFiles++
		n, err := verifyChecksumFile(path, opts.Dir, name)
		verified += n
		if err != nil {
			return err
		}
	}
	if checksumFiles == 0 {
		fmt.Fprintln(os.Stderr, "Warning: no SHA256SUMS or MD5SUMS found; skipping verification.")
	} else {
		fmt.Printf("Verified %d checksum entries.\n", verified)
	}
	if opts.VerifyOnly {
		return nil
	}

	tasks, err := unpackTasks(opts.Dir, entries)
	if err != nil {
		return err
	}
	needsPassphrase := false
	for _, task := range tasks {
		if task.Encrypted {
			needsPassphrase = true
		}
	}
	if needsPassphrase && opts.Passphrase == "" {
		if !term.IsTerminal(int(os.Stdin.Fd())) {
			return errors.New("encrypted files found; pass --passphrase or run interactively")
		}
		fmt.Fprint(os.Stderr, "Passphrase: ")
		raw, err := term.ReadPassword(int(os.Stdin.Fd()))
		fmt.Fprintln(os.Stderr)
		if err != nil {
			return err
		}
		opts.Passphrase = string(raw)
	}

	unpacked := 0
	for _, task := range tasks {
		if strings.ContainsAny(task.Original, "/\\") || task.Original == "" ||
			task.Original == "." || task.Original == ".." {
			return fmt.Errorf("refusing unsafe output name %q", task.Original)
		}
		finalPath := filepath.Join(opts.Dir, task.Original)
		if _, err := os.Stat(finalPath); err == nil && !opts.Force {
			return fmt.Errorf("output file %q already exists; use --force to overwrite", task.Original)
		}
		if err := unpackOne(filepath.Join(opts.Dir, task.Stored), finalPath, opts.Passphrase, opts.Dir, task.Compressed, task.Encrypted); err != nil {
			return fmt.Errorf("unpack %s: %w", task.Stored, err)
		}
		fmt.Printf("Unpacked %s -> %s\n", task.Stored, task.Original)
		unpacked++
	}
	if unpacked == 0 {
		fmt.Println("Nothing to unpack; all files are already in plain form.")
	} else {
		fmt.Printf("Unpacked %d file(s).\n", unpacked)
	}
	return nil
}

func isMetadataFile(name string) bool {
	switch name {
	case "SHA256SUMS", "MD5SUMS", "README-FERRY.txt", "FERRY-MANIFEST.json", "ferry":
		return true
	}
	return strings.HasPrefix(name, ".")
}

type unpackTask struct {
	Stored     string
	Original   string
	Compressed bool
	Encrypted  bool
}

type manifestEntry struct {
	Stored     string `json:"stored"`
	Original   string `json:"original"`
	Compressed bool   `json:"compressed"`
	Encrypted  bool   `json:"encrypted"`
}

// unpackTasks prefers the manifest written by Ferry. It falls back to the
// filename suffixes for images produced by older Ferry versions.
func unpackTasks(dir string, entries []os.DirEntry) ([]unpackTask, error) {
	manifestPath := filepath.Join(dir, "FERRY-MANIFEST.json")
	if data, err := os.ReadFile(manifestPath); err == nil {
		var manifest []manifestEntry
		if err := json.Unmarshal(data, &manifest); err != nil {
			return nil, fmt.Errorf("read FERRY-MANIFEST.json: %w", err)
		}
		tasks := make([]unpackTask, 0, len(manifest))
		for _, entry := range manifest {
			if !entry.Compressed && !entry.Encrypted && entry.Stored == entry.Original {
				continue
			}
			if strings.ContainsAny(entry.Stored, "/\\") || strings.ContainsAny(entry.Original, "/\\") {
				return nil, errors.New("FERRY-MANIFEST.json contains an unsafe filename")
			}
			tasks = append(tasks, unpackTask{
				Stored: entry.Stored, Original: entry.Original,
				Compressed: entry.Compressed, Encrypted: entry.Encrypted,
			})
		}
		return tasks, nil
	} else if !os.IsNotExist(err) {
		return nil, err
	}

	var tasks []unpackTask
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if isMetadataFile(name) {
			continue
		}
		output := name
		encrypted := strings.HasSuffix(output, securefile.Suffix)
		if encrypted {
			output = strings.TrimSuffix(output, securefile.Suffix)
		}
		compressed := strings.HasSuffix(output, ".gz")
		if compressed {
			output = strings.TrimSuffix(output, ".gz")
		}
		if output == name {
			continue
		}
		tasks = append(tasks, unpackTask{
			Stored: name, Original: output, Compressed: compressed, Encrypted: encrypted,
		})
	}
	return tasks, nil
}

func unpackOne(srcPath, finalPath, passphrase, dir string, compressed, encrypted bool) error {
	tmp, err := os.CreateTemp(dir, ".ferry-unpack-*")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() {
		_ = tmp.Close()
		_ = os.Remove(tmpName)
	}()

	src, err := os.Open(srcPath)
	if err != nil {
		return err
	}
	defer src.Close()

	var reader io.Reader = src
	if encrypted {
		pr, pw := io.Pipe()
		go func() {
			_, err := securefile.Decrypt(pw, src, passphrase)
			_ = pw.CloseWithError(err)
		}()
		reader = pr
	}
	if compressed {
		gz, err := gzip.NewReader(reader)
		if err != nil {
			return fmt.Errorf("open gzip stream: %w", err)
		}
		defer gz.Close()
		reader = gz
	}
	if _, err := io.Copy(tmp, reader); err != nil {
		return err
	}
	if err := tmp.Sync(); err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmpName, 0o644); err != nil {
		return err
	}
	return os.Rename(tmpName, finalPath)
}

func verifyChecksumFile(path, dir, label string) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	lineNo := 0
	checked := 0
	for scanner.Scan() {
		lineNo++
		line := strings.TrimRight(scanner.Text(), "\r")
		if strings.TrimSpace(line) == "" {
			continue
		}
		sep := strings.Index(line, "  ")
		if sep < 0 {
			return checked, fmt.Errorf("%s line %d is malformed (expected \"hash  filename\")", label, lineNo)
		}
		want := strings.ToLower(strings.TrimSpace(line[:sep]))
		name := strings.TrimPrefix(line[sep+2:], "*")
		if strings.ContainsAny(name, "/\\") || name == "" || name == "." || name == ".." {
			return checked, fmt.Errorf("%s line %d has an unsafe filename", label, lineNo)
		}
		filePath := filepath.Join(dir, name)
		var got string
		if label == "SHA256SUMS" {
			got, err = hashFileHex(filePath, "sha256")
		} else {
			got, err = hashFileHex(filePath, "md5")
		}
		if err != nil {
			return checked, fmt.Errorf("verify %s: %w", name, err)
		}
		if got != want {
			return checked, fmt.Errorf("checksum mismatch for %s: expected %s, got %s", name, want, got)
		}
		checked++
	}
	if err := scanner.Err(); err != nil {
		return checked, err
	}
	return checked, nil
}

func hashFileHex(path, algorithm string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	if algorithm == "sha256" {
		d := sha256.New()
		if _, err := io.Copy(d, f); err != nil {
			return "", err
		}
		return hex.EncodeToString(d.Sum(nil)), nil
	}
	d := md5.New()
	if _, err := io.Copy(d, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(d.Sum(nil)), nil
}
