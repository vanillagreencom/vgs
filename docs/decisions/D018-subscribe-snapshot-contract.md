# D018: A subscribe snapshot is a cached read, and an empty cache sends nothing

[← Decision Index](INDEX.md)

**Date**: 2026-09-13 **Status**: Active **Research**: —

**Context**: `subscribe` computed each service's snapshot by running that service's live query. Network ran about a dozen `nmcli` commands, bluez a `GetManagedObjects` sweep, wlroutput `hyprctl monitors`, tailscale two commands, cups `lpstat`, and brightness the Python helper. Every shell start, backend reconnect, and popout open re-sent `subscribe`, so those queries ran again while nothing else could be delivered.

**Decision**: `RegisterSnapshot` returns last-known-good state and must not block. A service whose state comes from an external command registers that query with `RegisterSnapshotRefresh`, which subscribe kicks onto the service's own goroutine through `backend/internal/refresh`. A service with no state yet returns `nil`, and subscribe sends no frame for it.

**Rationale**:

- A cached read cannot stall the connection that asked for it, nor the events queued behind it.
- An empty state is not a fact. Sending `{"printers": []}` before `lpstat` has ever run tells the shell there are no printers, which blanks a list the kicked refresh is about to fill.
- A `pending` marker on an empty state was the alternative. It keeps the wire shape but makes every client learn a new field to avoid acting on a state that means nothing. Sending no frame needs no client change, because the shell already ignores a service it has heard nothing from.
- The refresh result reaches clients through the same `Broadcast` path a live change uses, so there is one delivery path rather than two.

**Revisit When**: A client needs to distinguish "the backend has no state for this service" from "this service is absent", which no frame cannot express.

**Verification**: `backend/internal/server/server_test.go` covers the cached read, the refresh kick, and the nil snapshot. Each service's own test covers its empty cache.

**References**: `docs/architecture/backend.md` § Invariants.
