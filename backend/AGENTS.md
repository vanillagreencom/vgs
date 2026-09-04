# Backend changes

Read [../docs/architecture/backend.md](../docs/architecture/backend.md) for method, process and resource boundaries. Read [../docs/architecture/cloud-sync.md](../docs/architecture/cloud-sync.md) for sync changes.

Verify against a scratch daemon with `VGS_BACKEND_SOCKET=/run/user/$UID/test.sock vshell backend serve`, never the live socket. Keep socket paths short enough for the Unix socket address limit.
