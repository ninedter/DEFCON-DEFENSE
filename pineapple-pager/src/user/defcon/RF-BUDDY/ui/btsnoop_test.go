package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"strings"
	"testing"
)

func hx(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(strings.ReplaceAll(s, " ", ""))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

const (
	realA = "3E 29 02 01 00 00 6E 8C EC EB 68 02 1D 02 01 06 19 16 F7 FD 01 36 7C 66 8B B3 8D 50 42 AC 83 3F 2F 32 33 12 E2 00 00 00 00 03 B3"
	realB = "3E 2B 02 01 00 00 C5 0F CD BD 4D 74 1F 02 01 06 1B FF B5 B5 13 52 36 30 31 5A 41 42 37 58 46 43 54 30 39 32 38 63 00 01 00 00 3E 99 A6"
)

// legacy builds one legacy report entry; addr is reversed onto the wire.
func legacy(addr [6]byte, addrType byte, ad []byte, rssi int8) []byte {
	r := []byte{0x00 /* event_type */, addrType}
	for i := 5; i >= 0; i-- {
		r = append(r, addr[i])
	}
	r = append(r, byte(len(ad)))
	r = append(r, ad...)
	return append(r, byte(rssi))
}

func legacyEvt(reports ...[]byte) []byte {
	body := []byte{0x02, byte(len(reports))}
	for _, r := range reports {
		body = append(body, r...)
	}
	return append([]byte{0x3E, byte(len(body))}, body...)
}

func TestParseLEAdvertEvent(t *testing.T) {
	nano := append([]byte{0x02, 0x01, 0x06, 0x13, 0x09}, []byte("Nanoleaf Strip FCE")...)
	nano = append(nano, 0x02, 0x0A, 12)
	apple := []byte{0x02, 0x01, 0x06, 0x07, 0xFF, 0x4C, 0x00, 0x07, 0x19, 0x01, 0x02}
	msft := []byte{0x06, 0xFF, 0x06, 0x00, 0x03, 0x00, 0x80}
	fast := []byte{0x03, 0x16, 0x2C, 0xFE}
	odd := append([]byte{0x08, 0x09}, []byte("  caf\xc3\xa9\x01 ")...)
	a1 := [6]byte{1, 2, 3, 4, 5, 6}
	a2 := [6]byte{0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF}

	tests := []struct {
		name string
		pkt  []byte
		want []Advert
	}{
		{"real A", hx(t, realA), []Advert{{Addr: "02:68:EB:EC:8C:6E", RSSI: -77, Company: -1}}},
		{"real B", hx(t, realB), []Advert{{Addr: "74:4D:BD:CD:0F:C5", RSSI: -90, Company: 0xB5B5}}},
		{"name+tx", legacyEvt(legacy(a1, 0, nano, -60)),
			[]Advert{{Addr: "01:02:03:04:05:06", RSSI: -60, Name: "NANOLEAF STRIP FCE", TxPower: 12, HasTx: true, Company: -1}}},
		{"airpods", legacyEvt(legacy(a1, 0, apple, -50)),
			[]Advert{{Addr: "01:02:03:04:05:06", RSSI: -50, Company: 0x4C, Kind: "AIRPODS"}}},
		{"swift pair", legacyEvt(legacy(a1, 0, msft, -50)),
			[]Advert{{Addr: "01:02:03:04:05:06", RSSI: -50, Company: 6, Kind: "SWIFT PAIR"}}},
		{"fast pair", legacyEvt(legacy(a1, 0, fast, -50)),
			[]Advert{{Addr: "01:02:03:04:05:06", RSSI: -50, Company: -1, Kind: "FAST PAIR"}}},
		{"non-ascii name", legacyEvt(legacy(a1, 1, odd, -50)),
			[]Advert{{Addr: "01:02:03:04:05:06", Random: true, RSSI: -50, Name: "CAF", Company: -1}}},
		{"two reports", legacyEvt(legacy(a1, 0, nil, -40), legacy(a2, 1, nil, -41)),
			[]Advert{{Addr: "01:02:03:04:05:06", RSSI: -40, Company: -1},
				{Addr: "AA:BB:CC:DD:EE:FF", Random: true, RSSI: -41, Company: -1}}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := ParseLEAdvertEvent(tc.pkt)
			if len(got) != len(tc.want) {
				t.Fatalf("got %+v", got)
			}
			for i := range got {
				if got[i] != tc.want[i] {
					t.Errorf("[%d] got %+v want %+v", i, got[i], tc.want[i])
				}
			}
		})
	}
}

func extEvt(addr [6]byte, ad []byte, rssi int8) []byte {
	r := []byte{0x13, 0x00, 0x01}
	for i := 5; i >= 0; i-- {
		r = append(r, addr[i])
	}
	r = append(r, 1, 0, 0xFF, 0x7F, byte(rssi), 0, 0, 0, 0, 0, 0, 0, 0, 0, byte(len(ad)))
	r = append(r, ad...)
	body := append([]byte{0x0D, 1}, r...)
	return append([]byte{0x3E, byte(len(body))}, body...)
}

func TestParseExtended(t *testing.T) {
	ad := append([]byte{0x05, 0x09}, []byte("Ext1")...)
	got := ParseLEAdvertEvent(extEvt([6]byte{1, 2, 3, 4, 5, 6}, ad, -70))
	want := Advert{Addr: "01:02:03:04:05:06", Random: true, RSSI: -70, Name: "EXT1", Company: -1}
	if len(got) != 1 || got[0] != want {
		t.Fatalf("got %+v want %+v", got, want)
	}
}

func TestParseTruncatedNeverPanics(t *testing.T) {
	for _, full := range [][]byte{hx(t, realA), hx(t, realB), extEvt([6]byte{1}, []byte{2, 1, 6}, -1)} {
		for n := 0; n < len(full); n++ {
			if got := ParseLEAdvertEvent(full[:n]); got != nil {
				t.Errorf("len %d: got %+v", n, got)
			}
		}
		// lying length fields must not panic either
		for i := range full {
			c := append([]byte(nil), full...)
			c[i] = 0xFF
			ParseLEAdvertEvent(c)
		}
	}
	if ParseLEAdvertEvent(hx(t, "3E 02 03 00")) != nil {
		t.Error("unknown subevent")
	}
}

func TestCompanyName(t *testing.T) {
	for id, want := range map[int]string{0x4C: "APPLE", 0x9E: "BOSE", 0x1234: "ID 1234", -1: ""} {
		if got := CompanyName(id); got != want {
			t.Errorf("%x: %q want %q", id, got, want)
		}
	}
}

func record(flags uint32, data []byte) []byte {
	var h [24]byte
	binary.BigEndian.PutUint32(h[0:], uint32(len(data)))
	binary.BigEndian.PutUint32(h[4:], uint32(len(data)))
	binary.BigEndian.PutUint32(h[8:], flags)
	return append(h[:], data...)
}

func header(dl uint32) []byte {
	h := append([]byte("btsnoop\x00"), 0, 0, 0, 1, 0, 0, 0, 0)
	binary.BigEndian.PutUint32(h[12:], dl)
	return h
}

func TestReadBTSnoop(t *testing.T) {
	a, b := hx(t, realA), hx(t, realB)
	t.Run("h4", func(t *testing.T) {
		s := header(1002)
		s = append(s, record(3, append([]byte{4}, a...))...)
		s = append(s, record(0, []byte{2, 1, 2, 3})...) // ACL, ignored
		s = append(s, record(3, append([]byte{4}, b...))...)
		var got []Advert
		if err := ReadBTSnoop(bytes.NewReader(s), func(x Advert) { got = append(got, x) }); err != nil {
			t.Fatal(err)
		}
		if len(got) != 2 || got[0].RSSI != -77 || got[1].Company != 0xB5B5 {
			t.Fatalf("got %+v", got)
		}
	})
	t.Run("raw", func(t *testing.T) {
		s := header(1001)
		s = append(s, record(2, a)...)
		s = append(s, record(0, b)...) // ACL data flag, ignored
		var n int
		if err := ReadBTSnoop(bytes.NewReader(s), func(Advert) { n++ }); err != nil || n != 1 {
			t.Fatalf("n=%d err=%v", n, err)
		}
	})
	t.Run("errors", func(t *testing.T) {
		if err := ReadBTSnoop(bytes.NewReader([]byte("nonsense nonsense")), nil); err == nil {
			t.Error("bad magic")
		}
		if err := ReadBTSnoop(bytes.NewReader(nil), nil); err != nil {
			t.Errorf("empty: %v", err)
		}
		s := append(header(1002), record(3, append([]byte{4}, a...))...)
		if err := ReadBTSnoop(bytes.NewReader(s[:len(s)-3]), func(Advert) {}); err == nil {
			t.Error("truncated record should error")
		}
	})
}
