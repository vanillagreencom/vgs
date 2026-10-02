# Keyboard

Covers: shell/Ui/foundation/KeyNav.qml, shell/Ui/foundation/KeyNavLogic.js, shell/Ui/feedback/KeyCaps.qml, shell/Ui/controls/**, shell/Ui/layout/**, shell/Ui/overlay/**, shell/Ui/feedback/Dialog.qml, scripts/check-keyboard.py, scripts/test-check-keyboard.py, scripts/test-key-nav-logic.js

Keyboard support is part of the component contract. A component that accepts a pointer action also gives the same action a keyboard path, or names the owning composite that supplies it.

## Standard

[D068](../decisions/D068-keyboard-first-standard.md) records keyboard support as a first-class design system standard.

| Id | Rule |
|---|---|
| F1 | A focusable control draws `FocusRing` while `visualFocus` holds. A text input draws it while `activeFocus` holds. A list, menu, grid or carousel uses its one selection as the focus indicator. |
| F2 | Tab follows reading order. No hidden, disabled or unusable item takes focus. |
| F3 | A surface opens on its primary input, else its list, else its focusable body. It never opens on an action that installs, removes or changes the system. A key-opened surface uses `Qt.ShortcutFocusReason`. A click-opened surface uses `Qt.MouseFocusReason`. |
| F4 | Modal surfaces keep Tab inside and wrap. A `Dialog` traps only while `modal` holds. |
| F5 | A popup restores focus to its opener when the opener still exists. A separate Hyprland surface returns to the previous client. |
| F6 | A composite widget is one tab stop. Lists, menus, tabs, segmented controls, radio groups, carousels and grids move their selection with arrows. |
| K1 | Escape backs out one level. A local edit or search clear may consume Escape before the surface closes. |
| K2 | Enter, Return and Space activate button-like controls. Space toggles checkable controls. Enter toggles them too. |
| K3 | Tab and Shift+Tab move between groups. Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+PageDown and Ctrl+PageUp switch tabs in a tabbed surface. |
| K4 | Arrows move inside composites. An arrow never runs an action. |
| K5 | Home and End move to first and last. PageUp and PageDown move by a visible page. Sliders use Home and End for min and max, and PageUp and PageDown for `pageStep`. |
| K6 | A searchable list sends printable text to its search field. A menu without a search field uses type-ahead. |
| K7 | A full-screen overlay implements `navigate(direction)` when Hyprland directional binds must move inside it. |
| K8 | Shift+F10 and the Menu key open a row context menu where right click opens one. |
| K9 | Delete removes the selected item where the pointer offers removal. |
| D1 | A non-obvious shortcut appears in `KeyCaps`, one footer hint row or the control tooltip. |
| D2 | A surface has at most one hint row. Escape, arrows, Enter, Tab and Space stay implicit in obvious contexts. |
| P1 | Every pointer action has a keyboard path. Hover-only affordances also show for keyboard focus or selection. |
| P2 | The bar takes no keyboard focus. A bar widget action has a global shortcut or launcher path, and the surface it opens is keyboard-driven. |

## Components

| Role | Contract | Proof |
|---|---|---|
| Button-like controls | `Button`, `IconButton`, `ToggleButton`, `Checkbox`, `Radio`, `Switch`, `BarItem`, `Disclosure` and `DeviceRow` activate from Enter and Return as well as Space. | `scripts/qml-tests/tst_button.qml`, `scripts/qml-tests/tst_toggles.qml`, `scripts/qml-tests/tst_disclosure.qml`, `scripts/qml-tests/tst_devicerow.qml` |
| Row menus | `DeviceRow` opens its overflow menu on Shift+F10 and the Menu key, read through `KeyNavLogic.intent`, and its overflow button is a tab stop. | `scripts/qml-tests/tst_devicerow.qml` |
| Composite controls | `KeyNav` owns roving movement, Home, End, PageUp, PageDown, activation, reveal and type-ahead. | `scripts/test-key-nav-logic.js` |
| Shortcut hints | `KeyCaps` converts shortcut strings into `Kbd` chips. | `scripts/test-key-nav-logic.js` |
| Key capture field | `ShortcutField` is one Tab stop. Space, Enter, Return and keypad Enter start a capture through `KeyNavLogic.activate`. While it captures, every key but Escape, Tab and Shift+Tab is the combo's: Escape cancels, and Tab and Shift+Tab cancel and move the focus. Its keyboard and clear buttons are Tab stops after it. Escape in its text entry restores the key in effect, and a second Escape returns to the box. | `scripts/qml-tests/tst_shortcutfield.qml`, `scripts/smoke/rows/key-capture.sh` |
| Sliders | A slider responds to Up, Down, Home, End, PageUp and PageDown. | `scripts/qml-tests/tst_slider.qml` |
| Popups | `Menu`, `Select` and `Popover` keep their own focus while open. | `scripts/qml-tests/tst_overlays.qml` |
| Static check | `scripts/check-keyboard.py` refuses click areas without a key path and focusable items without a focus indicator. | `scripts/test-check-keyboard.py` |

## Static check scope

The validation row runs `scripts/check-keyboard.py shell`. `vgs-plugin check` runs the same rule on a plugin tree before a plugin lands.

## Static markers

Use `// keyboard-path: <how the keyboard reaches this action>` directly above a click-only item when an ancestor or owning composite supplies the key path.

Use `// focus-indicator: <what shows focus>` directly above a focusable item when a `FocusRing` is not the indicator.

The marker names a present mechanism. It does not exempt a missing mechanism.

## Surface proof

| Surface | Keyboard path | Proving row | Findings |
|---|---|---|---|
| Core hosts | Summoned hosts focus `initialFocus` after `open()` returns. Key-opened surfaces use the shortcut focus reason and show a ring. Anchored flyouts use the mouse focus reason and hide the ring. Escape closes a surface when the plugin leaves it unaccepted. | `scripts/smoke/rows/surfaces.sh` | Fixed host initial focus and Escape. |
| Launcher overlay | The search field owns typed text. `KeyNav` moves the result cursor with arrows, Home, End and pages. Enter activates. Right opens only menu, link and open-with rows. Escape clears search, then pops a user-opened submenu, then closes. The entry implements `navigate(direction)` for D067 focus binds. | `scripts/smoke/rows/launcher.sh`, `scripts/smoke/rows/list-motion.sh`, `scripts/smoke/rows/overlay-capture.sh` | Fixed launcher rows and markers. File rows show the Shift+Enter path while selected. Declined the empty-root hint because the Categories tooltip and selected-row hint cover the hidden shortcuts without adding a permanent footer. VGS differs from Omarchy's menu by using `KeyNav` and a D067 `navigate` API instead of local SUPER+W/A/S/D handling, so `vgs.themes` can keep SUPER+W. |
| Launcher file flyout | Shift+F10 and Menu open the selected file's flyout. The flyout owns every key while open. `KeyNav` skips separators, Enter picks and Escape closes. | `scripts/smoke/rows/launcher.sh` | Fixed `ContextMenu.qml` and `LauncherRow.qml`. |
| Themes panel | `SUPER+CTRL+J` summons the panel. The panel opens on its list. `currentKey` is the keyboard selection and draws a `ListCursor` plate. The Displayed badge and check icon mark the applied theme. `KeyNav` moves, pages and type-aheads. Enter or Space runs the row click. Alt+D runs the selected row's secondary action. | `scripts/smoke/rows/themes.sh` | Fixed `ThemesPanel.qml` and `ThemeRow.qml`. VGS differs from Omarchy panels by using the core summoned-panel focus contract, not an Exclusive-to-OnDemand keyboard prime. |
| Theme browser | The view keeps the rail focused. Arrows and D067 focus binds move cards. Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+PageDown and Ctrl+PageUp switch tabs. Ctrl+U clears the filter. Escape leaves the download offer before it closes the browser. | `scripts/smoke/rows/theme-browser.sh` | Fixed the tab keys and hint row. |
| Wallpaper browser | The view keeps a keyboard item focused. Arrows and D067 focus binds move cards. Space and Enter activate the selected card. Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+PageDown and Ctrl+PageUp switch tabs. | `scripts/smoke/rows/theme-browser.sh` | Fixed Space activation and the hint row. |
| Notifications inbox | `SUPER+N` summons the notifications panel. The panel opens on the list. `KeyNav` moves the selected card with arrows, Home, End and pages. Enter opens it. Delete dismisses it. Left and Right select the card's action pills, and Enter or Space presses the selected pill. Tab reaches Silence, Mark read and the mode switch. Escape closes through the summoned-panel slot, and a focus loss to another window or a press beside the panel over a window or the desktop closes it. | `scripts/smoke/rows/notifications.sh` | Fixed `NotificationCard.qml`, `PillButton.qml`, `Toggle.qml` and the inbox ownership. The row asserts shortcut open, focused list, movement keys, Enter, Delete, pill keys, Tab to Silence, Escape, focus loss, a press beside the panel and the Delete planted control. VGS differs from Omarchy's passive notification layer by using a summoned `panel`, because Quickshell 0.3.1 did not deliver keyboard focus to the passive LayerHost path under VGS. |
| Notification toasts | Toasts take no keyboard focus, because stealing focus would send the user's typing to a transient notice. A user reaches the same notification actions through the inbox panel with `SUPER+N`. | `scripts/smoke/rows/notifications.sh`, `scripts/smoke/rows/layers.sh`, `scripts/smoke/rows/toasts.sh` | Declined toast focus by design. The inbox is the keyboard path. |
| Core toasts | Core toasts take no keyboard focus, because they expire and carry no action except close. A close button remains pointer-only so a toast cannot steal typed text from the focused app. | `scripts/smoke/rows/layers.sh`, `scripts/smoke/rows/toasts.sh` | Declined keyboard focus by design. |
| Updates panel | `SUPER+CTRL+U` summons the panel. The panel opens on the first source Disclosure. Space expands it, Tab reaches that source's Update button, Return runs the source update TUI, later Tab reaches Update everything, and Escape closes through the summoned-panel slot. The bar tooltip shows the key from `shell.shortcut.keys`. The widget's middle click has the flyout's Update everything button as its keyboard path. | `scripts/smoke/rows/updates.sh` | Fixed `Widget.qml` and added the shortcut. The key is unused by Omarchy's default binding files and by other VGS manifests. |
| Agent Warden panel | `SUPER+CTRL+Y` summons the panel. The panel opens on its primary setup or recovery button when present. Return runs only that fixture TUI or action in smoke, and Escape closes through the summoned-panel slot. The bar tooltip shows the key from `shell.shortcut.keys`. | `scripts/smoke/rows/agent-warden.sh` | Fixed the panel initial focus and added the shortcut. `SUPER+CTRL+A` is declined because Omarchy binds it to Audio, and Omarchy binds `SUPER+SHIFT+CTRL+A` to Agent. |
| Bar workspaces | The bar takes no keyboard focus. A workspace pill is reached through the user's own Hyprland workspace binds. | `scripts/smoke/rows/bar.sh` | Recorded the README note. |
| Settings window | The search field opens focused. Printable text typed elsewhere on the list goes to the search field. `KeyNav` moves the list cursor with arrows, pages and Ctrl+Home or Ctrl+End while the field keeps ordinary text-edit keys. Return opens the selected plugin. The back button receives keyboard focus when a key opened the page. Escape restores an uncommitted text or key edit, and a later Escape pops the page. The bar gear shows the `SUPER+M` shortcut from `shell.shortcut.keys`. A Keys row's key field is reached by Tab, starts a capture on Return and stores the combo pressed next; while it listens Hyprland's pass-through submap gives it bound combos ([D086](../decisions/D086-key-capture-passthrough-submap.md)). | `scripts/smoke/rows/manager.sh`, `scripts/smoke/rows/settings.sh`, `scripts/smoke/rows/windows.sh`, `scripts/smoke/rows/list-motion.sh`, `scripts/smoke/rows/key-capture.sh`, `scripts/smoke/rows/key-passthrough.sh` | Fixed Settings row switch markers, list navigation, typed search routing, edit Escape handling and the gear shortcut tooltip. VGS differs from Omarchy's panel pattern by using the application window focus chain and `KeyNav`, not a panel-wide key catcher, because Settings is a Hyprland toplevel. |
| System window | `SUPER+COMMA` opens it on the sidebar's search field, and a deep link opens it in its section. Typed text filters the sections, and printable text typed elsewhere in the sidebar goes to the field. `KeyNav` moves the `ListCursor` with Up, Down, pages and Ctrl+Home or Ctrl+End. Enter, or Right at the end of the query, enters the selected section; Enter on Shell & Plugins opens Settings, which Right never does. Escape leaves the section for the search field, then clears a query, then closes the window. | `scripts/smoke/rows/system-window.sh` | Recorded the window. VGS takes `SUPER+COMMA`, which Omarchy binds to Dismiss last notification, because the System plan's Q1 chose it and `vgs.notifications` binds no comma key, only `SUPER+N` for its inbox. |
| Dev Tools window | The scrollable body opens focused and scrolls from the keyboard. Tab reaches row actions in reading order and `ScrollArea` reveals each focused action. Return on an action opens only the row's floating TUI. The window opens over IPC, while the launcher offers the install, update and remove TUIs as actions. It has no manifest key because no existing first-party Dev Tools key convention is reserved for it. | `scripts/smoke/rows/devtools.sh` | Fixed initial focus. VGS differs from Omarchy's Development menu by keeping install choices in a Hyprland application window whose first focus is inert, not in a menu row that can run immediately. |
| Gallery | The scrollable body opens focused and scrolls from the keyboard. The Focus section draws a focused example for each focusable `qs.Ui` control, including buttons, choices, text fields, sliders, title buttons, tabs, disclosure, a device row, a dialog action, carousel, key caps and a `KeyNav` list. Dialog examples are non-modal, so Escape can close the window. The carousel examples keep Tab outside the carousel. | `scripts/smoke/rows/gallery.sh`, `scripts/sandbox-shots.sh focus` | Fixed the Focus section, dialog modality, carousel Tab policy and focus screenshots. VGS differs from Omarchy's dev gallery by showing component focus with `focusPreview` in a normal scrollable application window, while Omarchy uses one panel cursor model for its gallery. |
| Requirement notice | The notice dialog opens on its action, traps Tab while modal and closes on Escape. | `scripts/smoke/rows/notices.sh` | Recorded the core notice. |
| Polkit prompt | The password field opens focused. Enter submits. Escape cancels. | `scripts/smoke/rows/polkit.sh` | Recorded the authentication overlay. |
| Lock screen | The password field opens focused. Enter unlocks. Escape stays inside the lock surface. | `scripts/smoke/rows/lock.sh` | Recorded the lock surface. |
| Automations window | The list holds the keys: Up, Down, Home and End move its `ListCursor`, Enter opens the selected automation, Space turns it on or off and Delete asks to remove it. Ctrl+N starts a new automation from any control and Ctrl+S saves the open editor. Escape closes a confirmation, then the editor, then the window. | `scripts/smoke/rows/automations.sh` | The window landed after this audit with its own list key handler in `AutomationListPage.qml`, not `KeyNav`. Its keys meet the standard; moving them onto `KeyNav` is proposed as a follow-up, not done here, so this change does not rework a surface another issue just shipped. |
| Jarvis bar widget | The bar takes no keyboard focus. The global shortcuts `talk` (held, `SUPER+code:108`), `mute` (`SUPER+SHIFT+code:108`) and `stop` (`SUPER+ALT+PERIOD`) reach the widget's actions. | `scripts/smoke/rows/jarvis-keys.sh` | None. |

## Decisions

[D068](../decisions/D068-keyboard-first-standard.md) records the keyboard-first standard, the host focus rule and the shared navigator.
