package auth

import "testing"

func TestPasswordHashing(t *testing.T) {
	hash, err := HashPassword("a long enough password")
	if err != nil {
		t.Fatal(err)
	}
	if err := ValidateBcryptHash(hash); err != nil {
		t.Fatalf("generated hash rejected: %v", err)
	}
	ok, err := VerifyPassword("a long enough password", hash, "")
	if err != nil || !ok {
		t.Fatalf("VerifyPassword = %v, %v", ok, err)
	}
	ok, err = VerifyPassword("wrong password", hash, "")
	if err != nil || ok {
		t.Fatalf("wrong password accepted: %v, %v", ok, err)
	}
}

func TestValidateBcryptHashRejectsTruncated(t *testing.T) {
	if err := ValidateBcryptHash("$2a$10$abc"); err == nil {
		t.Fatal("truncated hash accepted")
	}
	if err := ValidateBcryptHash("not-a-hash"); err == nil {
		t.Fatal("plain text accepted as a hash")
	}
}

func TestPlaintextComparison(t *testing.T) {
	ok, err := VerifyPassword("secret", "", "secret")
	if err != nil || !ok {
		t.Fatalf("plaintext match = %v, %v", ok, err)
	}
	ok, _ = VerifyPassword("secret2", "", "secret")
	if ok {
		t.Fatal("plaintext mismatch accepted")
	}
}

func TestHashPasswordLength(t *testing.T) {
	if _, err := HashPassword("short"); err == nil {
		t.Fatal("short password accepted")
	}
}
