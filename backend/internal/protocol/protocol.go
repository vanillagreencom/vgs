// Package protocol defines the line-delimited JSON wire format shared by the
// VGS backend daemon and the QML client (Services/VGSBackendService.qml).
//
// Request:  {"id": 1, "method": "network.getState", "params": {}}
// Response: {"id": 1, "result": ...}  or  {"id": 1, "error": "..."}
// Event:    {"result": {"service": "network", "data": ...}}  (no id)
package protocol

import "encoding/json"

// Request is one client call. ID is echoed verbatim on the response; it is
// absent for fire-and-forget calls such as subscribe.
type Request struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

// Response carries either a request result or an error. With no ID and an Event
// in Result, it carries a subscription push.
type Response struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Result any             `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
}

// Event is the payload of a subscription push, carried in Response.Result.
type Event struct {
	Service string `json:"service"`
	Data    any    `json:"data"`
}
