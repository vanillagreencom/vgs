package cups

import (
	"bufio"
	"bytes"
	"strings"
)

func parseDevices(out []byte) []Device {
	var devices []Device
	scanner := bufio.NewScanner(bytes.NewReader(out))
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		class, uri, ok := strings.Cut(line, " ")
		if !ok {
			continue
		}
		safeURI := sanitizeURI(uri)
		info := deviceInstanceName(safeURI)
		if info == "" || info == extractHost(safeURI) {
			info = safeURI
		}
		devices = append(devices, Device{Class: class, URI: safeURI, Info: info, IP: extractHost(safeURI)})
	}
	if devices == nil {
		return []Device{}
	}
	return devices
}
