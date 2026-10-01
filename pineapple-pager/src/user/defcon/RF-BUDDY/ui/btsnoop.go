package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"strings"
)

// Advert is one decoded BLE advertising report.
type Advert struct {
	Addr    string // "AA:BB:CC:DD:EE:FF", display order (wire order reversed)
	Random  bool
	RSSI    int
	Name    string
	TxPower int
	HasTx   bool
	Company int // -1 when absent
	Kind    string
}

const (
	btsnoopHdrLen    = 16
	btsnoopRecLen    = 24
	btsnoopMaxPkt    = 1 << 16
	dlHCIUnenc       = 1001
	dlHCIUART        = 1002
	hciEvtLEMeta     = 0x3E
	hciSubLEAdv      = 0x02
	hciSubLEExtAdv   = 0x0D
	hciPktEvent      = 0x04
	extAdvHdrLen     = 24
	extTxUnavailable = 127
)

var btsnoopMagic = []byte("btsnoop\x00")

// ReadBTSnoop decodes a btsnoop stream and calls fn per LE advertising report.
func ReadBTSnoop(r io.Reader, fn func(Advert)) error {
	var hdr [btsnoopHdrLen]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return eofNil(err)
	}
	if !bytes.Equal(hdr[:8], btsnoopMagic) {
		return errors.New("btsnoop: bad magic")
	}
	dl := binary.BigEndian.Uint32(hdr[12:16])
	if dl != dlHCIUnenc && dl != dlHCIUART {
		return fmt.Errorf("btsnoop: unsupported datalink %d", dl)
	}
	var rec [btsnoopRecLen]byte
	var buf []byte
	for {
		if _, err := io.ReadFull(r, rec[:]); err != nil {
			return eofNil(err)
		}
		incl := binary.BigEndian.Uint32(rec[4:8])
		flags := binary.BigEndian.Uint32(rec[8:12])
		if incl > btsnoopMaxPkt {
			return errors.New("btsnoop: oversized record")
		}
		if cap(buf) < int(incl) {
			buf = make([]byte, incl)
		}
		buf = buf[:incl]
		if _, err := io.ReadFull(r, buf); err != nil {
			return err
		}
		pkt := buf
		if dl == dlHCIUART {
			if len(pkt) < 1 || pkt[0] != hciPktEvent {
				continue
			}
			pkt = pkt[1:]
		} else if flags&2 == 0 {
			continue // not a command/event record
		}
		for _, a := range ParseLEAdvertEvent(pkt) {
			fn(a)
		}
	}
}

func eofNil(err error) error {
	if err == io.EOF {
		return nil
	}
	return err
}

// ParseLEAdvertEvent decodes one HCI event (starting at the event code byte).
// Malformed or truncated input returns nil.
func ParseLEAdvertEvent(pkt []byte) []Advert {
	if len(pkt) < 4 || pkt[0] != hciEvtLEMeta || len(pkt) < 2+int(pkt[1]) {
		return nil
	}
	body := pkt[2 : 2+int(pkt[1])]
	if len(body) < 2 {
		return nil
	}
	sub, n, p := body[0], int(body[1]), body[2:]
	var out []Advert
	for i := 0; i < n; i++ {
		var a Advert
		var ad []byte
		switch sub {
		case hciSubLEAdv:
			// event_type, addr_type, addr[6], data_len, data, rssi
			if len(p) < 9 || len(p) < 9+int(p[8])+1 {
				return nil
			}
			dl := int(p[8])
			a.Random = p[1] != 0
			a.Addr = fmtAddr(p[2:8])
			ad = p[9 : 9+dl]
			a.RSSI = int(int8(p[9+dl]))
			p = p[9+dl+1:]
		case hciSubLEExtAdv:
			if len(p) < extAdvHdrLen || len(p) < extAdvHdrLen+int(p[extAdvHdrLen-1]) {
				return nil
			}
			dl := int(p[extAdvHdrLen-1])
			a.Random = p[2] != 0
			a.Addr = fmtAddr(p[3:9])
			if tx := int8(p[12]); tx != extTxUnavailable {
				a.TxPower, a.HasTx = int(tx), true
			}
			a.RSSI = int(int8(p[13]))
			ad = p[extAdvHdrLen : extAdvHdrLen+dl]
			p = p[extAdvHdrLen+dl:]
		default:
			return nil
		}
		parseAD(ad, &a)
		out = append(out, a)
	}
	return out
}

func fmtAddr(b []byte) string {
	return fmt.Sprintf("%02X:%02X:%02X:%02X:%02X:%02X", b[5], b[4], b[3], b[2], b[1], b[0])
}

// parseAD walks the [len][type][data] structures of an advert payload.
func parseAD(ad []byte, a *Advert) {
	a.Company = -1
	short := ""
	for len(ad) >= 2 {
		l := int(ad[0])
		if l == 0 || len(ad) < 1+l {
			break
		}
		typ, d := ad[1], ad[2:1+l]
		ad = ad[1+l:]
		switch typ {
		case 0x09:
			a.Name = sanitize(string(d))
		case 0x08:
			short = sanitize(string(d))
		case 0x0A:
			if len(d) >= 1 {
				a.TxPower, a.HasTx = int(int8(d[0])), true
			}
		case 0xFF:
			if len(d) >= 2 {
				a.Company = int(d[0]) | int(d[1])<<8
				if k := mfrKind(a.Company, d[2:]); k != "" && a.Kind == "" {
					a.Kind = k
				}
			}
		case 0x16:
			if len(d) >= 2 {
				switch int(d[0]) | int(d[1])<<8 {
				case 0xFE2C:
					a.Kind = "FAST PAIR"
				case 0xFD6F:
					a.Kind = "EXPOSURE NOTIF"
				}
			}
		}
	}
	if a.Name == "" {
		a.Name = short
	}
}

// mfrKind hints a device type from manufacturer data (after the company id).
func mfrKind(company int, d []byte) string {
	if len(d) < 1 {
		return ""
	}
	switch company {
	case 0x004C:
		switch d[0] {
		case 0x07:
			return "AIRPODS"
		case 0x10:
			return "NEARBY"
		case 0x12:
			return "FIND MY"
		case 0x09:
			return "AIRPLAY"
		case 0x02:
			return "IBEACON"
		}
	case 0x0006:
		if d[0] == 0x03 {
			return "SWIFT PAIR"
		}
	}
	return ""
}

// sanitize keeps printable ASCII, upper-cased and trimmed.
func sanitize(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if c := s[i]; c >= 0x20 && c <= 0x7E {
			b.WriteByte(c)
		}
	}
	return strings.ToUpper(strings.TrimSpace(b.String()))
}

var companyNames = map[int]string{
	0x004C: "APPLE", 0x0006: "MICROSOFT", 0x0075: "SAMSUNG", 0x00E0: "GOOGLE",
	0x0087: "GARMIN", 0x0157: "HUAWEI", 0x038F: "XIAOMI", 0x0059: "NORDIC",
	0x000F: "BROADCOM", 0x02E5: "ESPRESSIF", 0x0171: "AMAZON", 0x009E: "BOSE",
}

// CompanyName maps a Bluetooth company id to a short maker name.
func CompanyName(id int) string {
	if id < 0 {
		return ""
	}
	if n, ok := companyNames[id]; ok {
		return n
	}
	return fmt.Sprintf("ID %04X", id)
}
