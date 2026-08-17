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
		// class + URI only: a device URI never contains a space, so any further
		// tokens are a human-readable description. Folding them into the URI
		// would fail deviceURI validation later with a confusing complaint
		// about the address rather than about the parse.
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
