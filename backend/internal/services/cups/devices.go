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
		// Device URI fields cannot contain raw spaces. Remaining lpinfo tokens
		// describe the device and must not be included in its URI.
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		class := fields[0]
		safeURI := sanitizeURI(fields[1])
		info := deviceInstanceName(safeURI)
		devices = append(devices, Device{Class: class, URI: safeURI, Info: info, IP: extractHost(safeURI)})
	}
	if devices == nil {
		return []Device{}
	}
	return devices
}
