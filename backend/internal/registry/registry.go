// Package registry describes what the backend advertises in getServerInfo and
// in the initial "server" subscription event.
package registry

// Version stamps. apiVersion is the upstream-compatible ordinal and MUST stay
// truthful: it is 0 until the backend actually ships methods that behave like a
// given upstream release. Feature presence is expressed through Capabilities and
// Methods, never by inflating apiVersion. vgsApiVersion tracks VGS protocol
// revisions and is what the QML client uses for its compatibility check.
const (
	APIVersion    = 0
	VGSAPIVersion = 1
)

// CLIVersion is overridable at build time via -ldflags "-X .../registry.cliVersion=...".
var cliVersion = "dev"

// CLIVersion returns the backend build identifier.
func CLIVersion() string { return cliVersion }

// ServerInfo is returned by getServerInfo and sent as the initial "server"
// subscription event so the client can gate on capabilities/methods.
type ServerInfo struct {
	APIVersion    int      `json:"apiVersion"`
	VGSAPIVersion int      `json:"vgsApiVersion"`
	CLIVersion    string   `json:"cliVersion"`
	Capabilities  []string `json:"capabilities"`
	Methods       []string `json:"methods"`
}

// Info builds a ServerInfo from the live capability/method sets.
func Info(capabilities, methods []string) ServerInfo {
	if capabilities == nil {
		capabilities = []string{}
	}
	if methods == nil {
		methods = []string{}
	}
	return ServerInfo{
		APIVersion:    APIVersion,
		VGSAPIVersion: VGSAPIVersion,
		CLIVersion:    CLIVersion(),
		Capabilities:  capabilities,
		Methods:       methods,
	}
}
