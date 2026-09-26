// Package registry describes what the backend advertises in getServerInfo and
// in the initial "server" subscription event.
package registry

// APIVersion is the compatibility ordinal. VGSAPIVersion identifies the VGS
// protocol. Clients detect features through Capabilities and Methods.
const (
	APIVersion    = 0
	VGSAPIVersion = 1
)

// cliVersion accepts a build identifier through -ldflags "-X
// .../registry.cliVersion=...".
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
