# Shell runtime

Covers: quickshell/vshell/

The QML runtime draws every VGS surface and orchestrates the work that produces them. `shell.qml` is the Quickshell root and loads either the shell or the greeter; `Common/` holds shared paths, tokens and settings, `Services/` holds long-lived state and command bridges, `Modules/` holds visible surfaces, and `Widgets/` holds the shared primitives.

## Boundaries

- A service owns state, polling, an IPC surface or a command bridge; a module binds to services and draws. A module that grows its own process or state logic has taken a service's job.
- Work that is not pure UI leaves through `Paths.vshellCli` or through `Services/VGSBackendService.qml`. Parsing a format the helper owns, rendering a template, or writing outside the user's own config belongs on the far side of one of those seams.
- `Services/CompositorService.qml` is the single owner of compositor focus for the whole shell. Quickshell's `ToplevelManager` and `Hyprland` are process-wide singletons holding one connection each, so a second subscriber to compositor events is a second owner of the same resource. Enforced by `scripts/test-compositor-focus.js`.
- `Services/CaptureService.qml` is the single QML owner of capture state. The bundled widget id stays `screenRecord` for existing bar layouts while the product name is Capture.
- `Widgets/Launcher/` holds only components with more than one consumer. A panel used solely by the launcher plugin belongs inside that plugin; one used solely by the overview search belongs beside the overview search.
- `Widgets/Tooltip/` is not part of the `qs.Widgets` import surface. It holds the shared tooltip body, and consumers reach it through `VgsTooltip` or `VgsInlineTooltip`.

## Invariants

1. One session owns one shell. `shell.qml` runs `vshell instances guard` before loading the shell, and only an instance provably younger than a live peer yields. Every unknown — no CLI, unreadable registry, unprovable age, no answer within the timeout — fails open, so the guard can never keep the session shell from starting. Enforced by `scripts/check-validation-safety.sh`, which refuses tracked guidance that instructs a direct second launch.
2. A widget property backed by plugin data is a binding, so a setter calls `savePluginData` and assigns nothing. Assigning the property as well destroys that binding for that instance while its siblings keep following the change signal, and one persisted setting then renders as two different states across displays.
3. Follow-up work after a save happens where the change is observed, never where the save was issued. The bar's global plugin service emits its change signal synchronously; the instance-scoped service behind a desktop widget emits on the next event-loop turn, so a value read back in the setter is still the old one there.
4. A pill action must know how it was reached. The bar's hover controller and the widget-toggle IPC call both run `pillClickAction`, so hover activation is opt-in through `pillClickOnHover`, and an action whose effect is unrecoverable requires an origin of `"click"`. An unannounced invocation defaults to `"ipc"`, so a caller that forgets to declare an origin fails closed. Enforced by `scripts/test-pill-hover-safety.js`.
5. Hover drives launcher selection only while the hover gate is armed. The result list rebuilds under a motionless pointer on every keystroke and on every asynchronous search reply, so binding selection to pointer entry makes Enter launch whichever row arrived under the cursor. Enforced by `scripts/test-launcher-hover-latch.js`.
6. A result is attributed by what its payload says it is, never by the source its fetch was launched for. Launch tags race: a tag can be reassigned while the process holding it still runs. Every layer stamps its own identity on every path it returns from, failures included. Enforced by `scripts/test-ai-usage-provider.js` and `scripts/test-ai-usage-lifecycle.js`.
7. Source-scoped state is invalidated together with the setting that scopes it, and before the refetch. Relaunch is decided on whether the state on screen belongs to the selected source, not on whether the selection moved, because a there-and-back toggle answers no to the second question.
8. One surface owns a derived answer. Where a bar pill, a vertical pill and a popout header show the same number, they read it from one function, or a filter applied to one of them makes the three disagree.
9. The changelog version is the release version read from `quickshell/vshell/VERSION`, dismissal is recorded per version, and a fresh install writes the marker without showing the modal. There is no second version to bump.

## Decisions

[D003](../decisions/D003-system-tray-transport.md) keeps Quickshell's `SystemTray` as the tray's only transport, which is why the tray context menu shells out rather than moving to the helper or the backend.

[D004](../decisions/D004-overview-search-ownership-and-plugin-boundary.md) names the seam between core and the app-launcher plugin. Core reaches the plugin only through `PluginService`'s `appLauncherPluginId`, `toggleAppLauncher()` and `appLauncherOpen`, so the plugin id is written once and core shell code never names it. The plugin reaches core only through the sanctioned import surfaces plus the shared launcher panels; a bundled plugin importing another feature's directory is the reach that made the old launcher tree unmovable.
