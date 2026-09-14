# D018: A subscribe snapshot is a cached read, and a frame is replaced only where the newest subsumes it

[← Decision Index](INDEX.md)

**Date**: 2026-09-13 **Status**: Active **Research**: —

**Context**: `subscribe` computed each service's snapshot by running that service's live query. Network ran about a dozen `nmcli` commands, bluez a `GetManagedObjects` sweep, wlroutput `hyprctl monitors`, tailscale two commands, cups `lpstat`, and brightness the Python helper. Every shell start, backend reconnect, and popout open re-sent `subscribe`, so those queries ran again while nothing else could be delivered.

**Decision**: `RegisterSnapshot` returns last-known-good state and must not block. A service whose state comes from an external command registers that query with `RegisterSnapshotRefresh`, which subscribe kicks onto the service's own goroutine through `backend/internal/refresh`. A service with no state yet returns `nil`, and subscribe sends no frame for it. A repeat subscribe re-sends snapshots only for services the previous subscription did not cover, and kicks every covered service's refresh.

Replacing a queued frame with a newer one is opt-in, per service, through `CoalesceBroadcasts`, and per coalescing key for a `RegisterLatest` setter. A key may only be declared where the newest value subsumes every earlier one under that key.

**Rationale**:

- A cached read cannot stall the connection that asked for it, nor the events queued behind it.
- An empty state is not a fact. Sending `{"printers": []}` before `lpstat` has ever run tells the shell there are no printers, which blanks a list the kicked refresh is about to fill.
- A `pending` marker on an empty state was the alternative. It keeps the wire shape but makes every client learn a new field to avoid acting on a state that means nothing. Sending no frame needs no client change, because the shell already ignores a service it has heard nothing from.
- The refresh result reaches clients through the same `Broadcast` path a live change uses, so there is one delivery path rather than two.
- Coalescing every service by name would be wrong for most of them. A per-URL open request, a per-device pairing prompt, a per-SSID credential prompt and a per-subscription D-Bus signal all travel under one service name, and replacing one with another loses it outright with nothing to report it. A lock or suspend flag is an edge the shell acts on, so it is not whole state either. Opt-in puts the judgement with the service that owns the payload.
- A keep-latest key of the method name alone has the same defect one level down: `brightness.setBrightness` addresses one display, so a write to the second display would evict the waiting write to the first and that display would never be written.
- A replaced call is answered as a success carrying `superseded`, not as an error. Supersession means a newer call took over the caller's intent. Shipped clients treat an error frame as a failed write: they raise a toast, clear the device's state, and in one path skip the follow-up call that writes the night-mode schedule.

**Revisit When**: A client needs to distinguish "the backend has no state for this service" from "this service is absent", which no frame cannot express.

**Verification**: `backend/internal/server/server_test.go` covers the cached read, the refresh kick, the nil snapshot, the per-key keep-latest slot and the two coalescing paths. `backend/internal/server/queue_test.go` covers the shared queue. Each service's own test covers its empty cache.

**References**: `docs/architecture/backend.md` § Invariants.
