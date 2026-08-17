package cups

import (
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
)

func validatePPDName(value string) error {
	if value == "" || value != strings.TrimSpace(value) || strings.Contains(value, "..") {
		return fmt.Errorf("invalid ppd")
	}
	if rest, ok := strings.CutPrefix(value, "driverless:"); ok {
		return validateDeviceURI(rest)
	}
	if !ppdRe.MatchString(value) {
		return fmt.Errorf("invalid ppd")
	}
	return nil
}

func validateDeviceURI(raw string) error {
	if raw == "" || raw != strings.TrimSpace(raw) || len(raw) > 1024 || strings.ContainsAny(raw, " \r\n\t") {
		return fmt.Errorf("invalid deviceURI")
	}
	scheme, rest, ok := strings.Cut(raw, ":")
	if !ok || scheme == "" || rest == "" {
		return fmt.Errorf("invalid deviceURI")
	}
	switch strings.ToLower(scheme) {
	case "ipp", "ipps", "lpd", "socket", "http", "https":
		return validateNetworkDeviceURI(rest)
	case "dnssd", "usb":
		return validateAuthorityDeviceURI(rest)
	case "parallel", "serial":
		return validateDevicePathURI(rest)
	default:
		return fmt.Errorf("unsupported deviceURI scheme")
	}
}

func validateNetworkDeviceURI(rest string) error {
	host, port, err := splitDeviceAuthority(rest)
	if err != nil {
		return err
	}
	if port != "" {
		n, err := strconv.Atoi(port)
		if err != nil || n <= 0 || n > 65535 {
			return fmt.Errorf("invalid deviceURI port")
		}
	}
	return validateDeviceHost(host)
}

// dnssd and usb always name their device through an authority, so a path-form
// value for them is malformed rather than a shorthand — accepting it would let
// the URI reach CUPS tooling with no host ever validated.
func validateAuthorityDeviceURI(rest string) error {
	host, _, err := splitDeviceAuthority(rest)
	if err != nil {
		return err
	}
	return validateDeviceHost(host)
}

// parallel and serial address a local device node (parallel:/dev/lp0) and carry
// no authority; an authority form for them is validated as a host.
func validateDevicePathURI(rest string) error {
	if strings.HasPrefix(rest, "//") {
		host, _, err := splitDeviceAuthority(rest)
		if err != nil {
			return err
		}
		return validateDeviceHost(host)
	}
	if !strings.HasPrefix(rest, "/") || strings.Contains(rest, "@") {
		return fmt.Errorf("invalid deviceURI")
	}
	return nil
}

func splitDeviceAuthority(rest string) (host, port string, err error) {
	if !strings.HasPrefix(rest, "//") {
		return "", "", fmt.Errorf("invalid deviceURI")
	}
	authority := rest[2:]
	if i := strings.IndexAny(authority, "/?#"); i >= 0 {
		authority = authority[:i]
	}
	if authority == "" {
		return "", "", fmt.Errorf("invalid deviceURI host")
	}
	if strings.Contains(authority, "@") {
		return "", "", fmt.Errorf("deviceURI must not include credentials")
	}
	host, port, err = splitHostPort(authority)
	if err != nil {
		return "", "", fmt.Errorf("invalid deviceURI host")
	}
	return host, port, nil
}

func splitHostPort(authority string) (host, port string, err error) {
	if strings.HasPrefix(authority, "[") {
		end := strings.IndexByte(authority, ']')
		if end <= 1 {
			return "", "", fmt.Errorf("invalid host")
		}
		host = authority[1:end]
		rest := authority[end+1:]
		if rest == "" {
			return host, "", nil
		}
		if !strings.HasPrefix(rest, ":") || rest == ":" {
			return "", "", fmt.Errorf("invalid host")
		}
		return host, rest[1:], nil
	}
	// An unbracketed authority holding more than one colon is a bare IPv6
	// literal, which RFC 3986 does not allow: splitting on the last colon would
	// carve a host that parses as a valid address out of a malformed URI and
	// hand CUPS a different target than the one written.
	if strings.Count(authority, ":") > 1 {
		return "", "", fmt.Errorf("invalid host")
	}
	if i := strings.LastIndexByte(authority, ':'); i >= 0 {
		if !isAllDigits(authority[i+1:]) {
			return "", "", fmt.Errorf("invalid host")
		}
		return authority[:i], authority[i+1:], nil
	}
	return authority, "", nil
}

func isAllDigits(value string) bool {
	if value == "" {
		return false
	}
	for _, r := range value {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// CUPS Bonjour/dnssd instance names percent-encode spaces in the host. Go's
// url.Parse rejects that as an invalid host escape, so device hosts are
// unescaped and checked without RFC hostname rules.
func validateDeviceHost(host string) error {
	decoded, err := url.PathUnescape(host)
	if err != nil {
		return fmt.Errorf("invalid deviceURI host")
	}
	decoded = strings.TrimSpace(decoded)
	if decoded == "" || len(decoded) > 253 {
		return fmt.Errorf("invalid deviceURI host")
	}
	if ip := net.ParseIP(strings.Trim(decoded, "[]")); ip != nil {
		return nil
	}
	for _, r := range decoded {
		if r < 0x20 || r == 0x7f || strings.ContainsRune("/@?#\\", r) {
			return fmt.Errorf("invalid deviceURI host")
		}
	}
	return nil
}

func validateHost(host string) error {
	host = strings.TrimSpace(host)
	if host == "" || len(host) > 253 || strings.ContainsAny(host, "/@ \r\n\t") {
		return fmt.Errorf("invalid host")
	}
	if ip := net.ParseIP(host); ip != nil {
		return nil
	}
	if strings.Contains(host, "_") {
		return fmt.Errorf("invalid host")
	}
	trimmed := strings.TrimSuffix(host, ".")
	if trimmed == "" {
		return fmt.Errorf("invalid host")
	}
	for _, label := range strings.Split(trimmed, ".") {
		if label == "" || len(label) > 63 || strings.HasPrefix(label, "-") || strings.HasSuffix(label, "-") {
			return fmt.Errorf("invalid host")
		}
		for _, r := range label {
			if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' {
				continue
			}
			return fmt.Errorf("invalid host")
		}
	}
	return nil
}

func sanitizeURI(raw string) string {
	scheme, rest, ok := strings.Cut(raw, ":")
	if !ok || !strings.HasPrefix(rest, "//") {
		return raw
	}
	body := rest[2:]
	cut := len(body)
	if i := strings.IndexAny(body, "/?#"); i >= 0 {
		cut = i
	}
	_, hostport, found := strings.Cut(body[:cut], "@")
	if !found {
		return raw
	}
	return scheme + "://" + hostport + body[cut:]
}

func extractHost(uri string) string {
	_, rest, ok := strings.Cut(uri, "://")
	if !ok {
		return ""
	}
	host := rest
	if i := strings.IndexAny(host, "/?#"); i >= 0 {
		host = host[:i]
	}
	if _, hostport, found := strings.Cut(host, "@"); found {
		host = hostport
	}
	if strings.HasPrefix(host, "[") {
		if end := strings.IndexByte(host, ']'); end > 1 {
			return host[1:end]
		}
	}
	if i := strings.LastIndexByte(host, ':'); i >= 0 && isAllDigits(host[i+1:]) {
		host = host[:i]
	}
	if decoded, err := url.PathUnescape(host); err == nil {
		return decoded
	}
	return host
}

func hasBonjourServiceSuffix(host string) bool {
	lower := strings.ToLower(host)
	return strings.Contains(lower, "._ipp._tcp") || strings.Contains(lower, "._ipps._tcp") || strings.Contains(lower, "._printer._tcp") || strings.Contains(lower, "._pdl-datastream._tcp")
}

func deviceInstanceName(raw string) string {
	host := extractHost(raw)
	if host == "" || !hasBonjourServiceSuffix(host) {
		return ""
	}
	lower := strings.ToLower(host)
	for _, suffix := range []string{
		"._ipp._tcp.local", "._ipps._tcp.local", "._printer._tcp.local",
		"._pdl-datastream._tcp.local", "._ipp._tcp", "._ipps._tcp", "._printer._tcp",
	} {
		if strings.HasSuffix(lower, suffix) {
			return strings.TrimSpace(host[:len(host)-len(suffix)])
		}
	}
	if i := strings.Index(host, "."); i > 0 {
		return strings.TrimSpace(host[:i])
	}
	return ""
}

func buildManualDeviceURI(protocol, host string, port int, queue string) (string, error) {
	proto := strings.ToLower(strings.TrimSpace(protocol))
	if proto == "" {
		proto = "ipp"
	}
	if proto == "jetdirect" {
		proto = "socket"
	}
	if err := validateHost(host); err != nil {
		return "", err
	}
	if err := validateProtocol(proto); err != nil {
		return "", err
	}
	queue = strings.TrimSpace(queue)
	if queue != "" {
		if err := validateName("queue", queue); err != nil {
			return "", err
		}
	}
	if port <= 0 {
		port = defaultPort(proto)
	}
	if port <= 0 || port > 65535 {
		return "", fmt.Errorf("port out of range")
	}
	hostport := net.JoinHostPort(host, strconv.Itoa(port))
	switch proto {
	case "ipp", "ipps":
		return proto + "://" + hostport + "/ipp/print", nil
	case "http", "https":
		return proto + "://" + hostport + "/", nil
	case "socket":
		return "socket://" + hostport, nil
	case "lpd":
		// CUPS reads the final path component as the LPD queue name;
		// passthru preserves raw-server behavior when none is given.
		if queue == "" {
			queue = "passthru"
		}
		return "lpd://" + hostport + "/" + queue, nil
	default:
		return proto + "://" + hostport, nil
	}
}
