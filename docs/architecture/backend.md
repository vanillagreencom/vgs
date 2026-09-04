# Backend daemon

Covers: backend/

The backend provides live system integration over a same-user local socket. Its method contract is [../../backend/methods.json](../../backend/methods.json).

## Boundaries

- The runner owns the listener and child processes. The daemon owns registered services. See `backend/internal/runner/` and its tests.
- Theme generation belongs to the helper. Display power belongs to QML's idle service. The backend only schedules wallpaper rotation and reports relevant session events.
- External commands use argv arrays. Credentials and payloads must not enter logs. These are review requirements, not a repository-wide static guarantee.

## Invariants

- Every registered Go method requires an inventory capability. Excluded methods must not be registered; excluded QML references require a removal action. `scripts/check-backend-inventory.py` checks this distinction.
- QML uses advertised methods or capabilities and retains a fallback for unavailable features. `Services/VGSBackendService.qml` owns negotiation; the inventory check rejects raw version comparisons in its scanned callers.
- The socket rejects other users and requires a runtime directory. See `backend/internal/server/` and its tests.
- D-Bus access is limited to the registered subscription routes. The inventory and `backend/internal/services/dbusbridge/` define the permitted scope.
- Daemon supervision has bounded restarts and preserves the listener while restarting. See `backend/internal/runner/` and its tests.
- One-shot commands use `backend/internal/execbound`; long-lived processes require an explicit lifecycle owner. `scripts/check-execbound-adoption.py` checks raw command builders against its lifecycle exceptions.

## Decisions

[D009](../decisions/D009-manifest-second-reader.md).
