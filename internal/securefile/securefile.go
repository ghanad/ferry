// Package securefile implements the optional per-job passphrase encryption
// used before files are packed into an image. It streams data in 1 MiB
// AES-256-GCM chunks so multi-gigabyte files never sit in memory.
package securefile

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"

	"golang.org/x/crypto/scrypt"
)

const (
	// Magic marks an encrypted Ferry file.
	Magic = "FERRYENC"
	// Version is the current on-disk format.
	Version = 1
	// SaltSize is the random scrypt salt length.
	SaltSize = 16
	// Suffix is appended to encrypted files.
	Suffix = ".ferry"

	headerSize = len(Magic) + 1 + SaltSize + 8
	chunkSize  = 1 << 20
	tagSize    = 16
	maxChunk   = chunkSize + tagSize

	scryptN = 1 << 15
	scryptR = 8
	scryptP = 1
	keyLen  = 32
)

// ErrNotEncrypted means the file does not start with the Ferry magic header.
var ErrNotEncrypted = errors.New("file is not encrypted by Ferry")

// ErrWrongPassphrase means the passphrase could not authenticate the data.
var ErrWrongPassphrase = errors.New("wrong passphrase or corrupted encrypted file")

// NewSalt returns a fresh random salt.
func NewSalt() ([]byte, error) {
	salt := make([]byte, SaltSize)
	if _, err := rand.Read(salt); err != nil {
		return nil, fmt.Errorf("generate encryption salt: %w", err)
	}
	return salt, nil
}

// Encrypt writes an encrypted copy of src to dst. plainSize must be the exact
// number of bytes in src; it is authenticated in the header. The same salt and
// input always produce the same output, which lets Ferry hash the stored bytes
// before the layer is streamed.
func Encrypt(dst io.Writer, src io.Reader, passphrase string, salt []byte, plainSize int64) error {
	if passphrase == "" {
		return errors.New("passphrase is empty")
	}
	if len(salt) != SaltSize {
		return fmt.Errorf("salt must be %d bytes", SaltSize)
	}
	if plainSize < 0 {
		return errors.New("plaintext size cannot be negative")
	}
	key, err := deriveKey(passphrase, salt)
	if err != nil {
		return err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return fmt.Errorf("initialize encryption: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return fmt.Errorf("initialize encryption: %w", err)
	}

	header := make([]byte, headerSize)
	copy(header, Magic)
	header[len(Magic)] = Version
	copy(header[len(Magic)+1:], salt)
	binary.BigEndian.PutUint64(header[len(Magic)+1+SaltSize:], uint64(plainSize))
	if _, err := dst.Write(header); err != nil {
		return fmt.Errorf("write encryption header: %w", err)
	}

	buf := make([]byte, chunkSize)
	nonce := make([]byte, 12)
	var counter uint32
	var written int64
	for written < plainSize {
		want := int64(chunkSize)
		if remaining := plainSize - written; remaining < want {
			want = remaining
		}
		if _, err := io.ReadFull(src, buf[:want]); err != nil {
			return fmt.Errorf("read plaintext: %w", err)
		}
		binary.BigEndian.PutUint32(nonce[:4], counter)
		sealed := gcm.Seal(nil, nonce, buf[:want], header)
		var length [4]byte
		binary.BigEndian.PutUint32(length[:], uint32(len(sealed)))
		if _, err := dst.Write(length[:]); err != nil {
			return fmt.Errorf("write encrypted chunk: %w", err)
		}
		if _, err := dst.Write(sealed); err != nil {
			return fmt.Errorf("write encrypted chunk: %w", err)
		}
		written += want
		counter++
	}
	return nil
}

// Decrypt streams an encrypted Ferry file from src to dst and returns the
// number of plaintext bytes written.
func Decrypt(dst io.Writer, src io.Reader, passphrase string) (int64, error) {
	if passphrase == "" {
		return 0, errors.New("a passphrase is required to decrypt this file")
	}
	header := make([]byte, headerSize)
	if _, err := io.ReadFull(src, header); err != nil {
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			return 0, ErrNotEncrypted
		}
		return 0, fmt.Errorf("read encryption header: %w", err)
	}
	if string(header[:len(Magic)]) != Magic {
		return 0, ErrNotEncrypted
	}
	if header[len(Magic)] != Version {
		return 0, fmt.Errorf("unsupported Ferry encryption version %d", header[len(Magic)])
	}
	salt := header[len(Magic)+1 : len(Magic)+1+SaltSize]
	plainSize := int64(binary.BigEndian.Uint64(header[len(Magic)+1+SaltSize:]))
	if plainSize < 0 {
		return 0, errors.New("invalid encrypted file header")
	}
	key, err := deriveKey(passphrase, salt)
	if err != nil {
		return 0, err
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		return 0, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return 0, err
	}

	nonce := make([]byte, 12)
	var counter uint32
	var written int64
	for written < plainSize {
		var length [4]byte
		if _, err := io.ReadFull(src, length[:]); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return written, fmt.Errorf("encrypted file is truncated (expected %d bytes, found %d)", plainSize, written)
			}
			return written, fmt.Errorf("read encrypted chunk: %w", err)
		}
		size := int(binary.BigEndian.Uint32(length[:]))
		if size <= tagSize || size > maxChunk {
			return written, errors.New("encrypted file is corrupted (invalid chunk length)")
		}
		sealed := make([]byte, size)
		if _, err := io.ReadFull(src, sealed); err != nil {
			return written, fmt.Errorf("encrypted file is truncated: %w", err)
		}
		binary.BigEndian.PutUint32(nonce[:4], counter)
		chunk, err := gcm.Open(nil, nonce, sealed, header)
		if err != nil {
			return written, ErrWrongPassphrase
		}
		if written+int64(len(chunk)) > plainSize {
			return written, errors.New("encrypted file is corrupted (more data than declared)")
		}
		if _, err := dst.Write(chunk); err != nil {
			return written, fmt.Errorf("write decrypted data: %w", err)
		}
		written += int64(len(chunk))
		counter++
	}
	if written != plainSize {
		return written, fmt.Errorf("encrypted file is truncated (expected %d bytes, found %d)", plainSize, written)
	}
	return written, nil
}

// IsEncryptedFile reports whether path starts with the Ferry magic header.
func IsEncryptedFile(path string) (bool, error) {
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	head := make([]byte, len(Magic))
	n, err := io.ReadFull(f, head)
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return false, err
	}
	return n == len(Magic) && string(head) == Magic, nil
}

func deriveKey(passphrase string, salt []byte) ([]byte, error) {
	key, err := scrypt.Key([]byte(passphrase), salt, scryptN, scryptR, scryptP, keyLen)
	if err != nil {
		return nil, fmt.Errorf("derive encryption key: %w", err)
	}
	return key, nil
}

// Fingerprint is a short, non-reversible identifier for a passphrase. It is
// only used to confirm that the same passphrase is being retried.
func Fingerprint(passphrase string) string {
	sum := sha256.Sum256([]byte("ferry-passphrase:" + passphrase))
	return fmt.Sprintf("%x", sum[:6])
}

// HeaderSize is the fixed size of the encrypted file header.
const HeaderSize = headerSize

// ChunkSize is the plaintext chunk size used by Encrypt.
const ChunkSize = chunkSize

// EncryptedSize returns the exact stored size for plainSize plaintext bytes.
func EncryptedSize(plainSize int64) int64 {
	if plainSize < 0 {
		return 0
	}
	chunks := plainSize / chunkSize
	if plainSize%chunkSize != 0 {
		chunks++
	}
	return int64(headerSize) + plainSize + chunks*(4+tagSize)
}
