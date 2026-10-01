package main

import (
	"io/fs"
	"strings"
	"testing"
)

func TestCompanyBrand(t *testing.T) {
	for id, want := range map[int]string{0x004C: "APPLE", 0x0006: "MICROSOFT", 0x0075: "SAMSUNG", 0x005D: "REALTEK", 0x00E0: "GOOGLE"} {
		b, full, ok := CompanyBrand(id)
		if !ok || b != want || full == "" {
			t.Errorf("CompanyBrand(%#x) = %q,%q,%v; want %q", id, b, full, ok, want)
		}
	}
	if _, _, ok := CompanyBrand(0xB5B5); ok {
		t.Error("0xB5B5 should be unknown")
	}
}

func TestMemberBrand(t *testing.T) {
	for id, want := range map[int]string{0xFEED: "TILE", 0xFEEC: "TILE", 0xFE9F: "GOOGLE"} {
		if b, _, ok := MemberBrand(id); !ok || b != want {
			t.Errorf("MemberBrand(%#x) = %q,%v; want %q", id, b, ok, want)
		}
	}
	if _, _, ok := MemberBrand(0x0001); ok {
		t.Error("0x0001 should not be a member UUID")
	}
}

func TestServiceName(t *testing.T) {
	if n, ok := ServiceName(0x180D); !ok || !strings.Contains(n, "HEART RATE") {
		t.Errorf("ServiceName(0x180D) = %q,%v", n, ok)
	}
	if _, ok := ServiceName(0xFFFF); ok {
		t.Error("0xFFFF should be unknown")
	}
}

func TestAppearanceName(t *testing.T) {
	if n, ok := AppearanceName(0x03C1); !ok || n != "KEYBOARD" {
		t.Errorf("0x03C1 = %q,%v", n, ok)
	}
	if n, ok := AppearanceName(0x0941); !ok || n != "EARBUD" {
		t.Errorf("0x0941 = %q,%v", n, ok)
	}
	// Unknown subcategory falls back to the category.
	if n, ok := AppearanceName(0x0040 | 0x3F); !ok || n != "PHONE" {
		t.Errorf("category fallback = %q,%v", n, ok)
	}
	if _, ok := AppearanceName(0xFFFF); ok {
		t.Error("0xFFFF should be unknown")
	}
}

func TestOUIBrand(t *testing.T) {
	for _, a := range []string{"F8:FF:C2:12:34:56", "f8:ff:c2:12:34:56", "F8:FF:C2", "F8-FF-C2-00-00-00"} {
		if b, ok := OUIBrand(a); !ok || b != "APPLE" {
			t.Errorf("OUIBrand(%q) = %q,%v", a, b, ok)
		}
	}
	for _, a := range []string{"", "F8:FF", "ZZ:FF:C2:00:00:00", "F8FFC2123456", "F8:FF:C2x12", "02:11:22:00:00:00"} {
		if b, ok := OUIBrand(a); ok {
			t.Errorf("OUIBrand(%q) = %q, want not ok", a, b)
		}
	}
}

func TestBtdbSizeAndASCII(t *testing.T) {
	total := int64(0)
	ents, err := fs.ReadDir(btdbFS, "btdb")
	if err != nil || len(ents) < 5 {
		t.Fatalf("embedded btdb dir: %v (%d entries)", err, len(ents))
	}
	for _, e := range ents {
		info, err := e.Info()
		if err != nil {
			t.Fatal(err)
		}
		total += info.Size()
	}
	if total > 1536*1024 {
		t.Errorf("embedded data %d bytes exceeds 1.5 MB", total)
	}
	tb := btdbLoad()
	for id, n := range tb.companies {
		if len(n.brand) > 16 || len(n.full) > 26 {
			t.Fatalf("company %#x too long: %q / %q", id, n.brand, n.full)
		}
	}
	for _, b := range tb.oui {
		if len(b) > 16 || b == "" {
			t.Fatalf("bad OUI brand %q", b)
		}
	}
	if len(tb.companies) < 3000 || len(tb.oui) < 20000 {
		t.Errorf("tables look truncated: %d companies, %d oui", len(tb.companies), len(tb.oui))
	}
}
