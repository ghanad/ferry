package secretbox

import "testing"

func TestSealOpen(t *testing.T) {
	secret := "0123456789abcdef0123456789abcdef"
	encoded, err := Seal(secret, "correct horse battery staple")
	if err != nil {
		t.Fatal(err)
	}
	if encoded == "" || encoded == "correct horse battery staple" {
		t.Fatalf("unexpected encoded value %q", encoded)
	}
	got, err := Open(secret, encoded)
	if err != nil {
		t.Fatal(err)
	}
	if got != "correct horse battery staple" {
		t.Fatalf("Open = %q", got)
	}
}

func TestOpenWrongSecret(t *testing.T) {
	encoded, err := Seal("secret-one", "passphrase")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Open("secret-two", encoded); err == nil {
		t.Fatal("expected an error with the wrong secret")
	}
}

func TestOpenEmpty(t *testing.T) {
	got, err := Open("secret", "")
	if err != nil || got != "" {
		t.Fatalf("Open empty = %q, %v", got, err)
	}
}
