# Jarvis bubble and indicator

Covers: shell/plugins/vgs.jarvis/Bubble.qml, shell/plugins/vgs.jarvis/Service.qml, shell/plugins/vgs.jarvis/Session.js, shell/plugins/vgs.jarvis/JarvisProtocol.js, shell/plugins/vgs.jarvis/backend/jarvisd.js, scripts/smoke/rows/jarvis-bubble.sh, scripts/smoke/rows/jarvis-keys.sh, scripts/fixtures/jarvis/scripted.js

The service registers one [passive layer](layers.md), independently of any bar or widget. Unplacing the bar widget leaves the service and its indicator registered. [D060](../decisions/D060-passive-voice-orb.md) keeps the orb decorative. [D064](../decisions/D064-jarvis-child-lease.md) binds capture to the service and its presented indicator.

## Demand and presentation

`Session.indicatorWanted` derives visual demand from capture, phase and retained input demand. Input can wait for the indicator while capture remains closed. Using capture alone would deadlock: Session admits capture only after the indicator is shown. Ready idle, muted idle and the stock unconfigured daemon request no map.

Each `Bubble.qml` copy declares `shown` only for the output named by `Hyprland.focusedMonitor`, while the service is ready, unlocked and wants a visual. A missing focused output maps none. [The Quickshell Hyprland reference](https://quickshell.org/docs/v0.3.1/types/Quickshell.Hyprland/Hyprland/) defines that observation. The host clears reserved space. The composition centres its card above the bottom by `Theme.voiceBubble.margin`. `Surface`, `Pane`, `Label`, `VoiceOrb`, `IconButton` and `Tooltip` own drawing and layout.

The service owns the set of its live copies. A copy reports `presented` only while it requests a map, is visible, has the passive host's presentation acknowledgment and fits inside usable host geometry. Losing the screen, map, focused output, daemon or lock observation revokes availability. Destroying a copy removes it from the same owner. Restart resets wire delivery and waits for new daemon state.

The service sends `indicator { shown }` with its observed generation and snapshot revision. `JarvisProtocol.accept` checks direction, exact shape and boolean value. The daemon refuses an observation before hello or for another revision. Indicator input describes the service lifetime, not an asynchronous turn result. A gone observation must reach Session even when its observed generation predates a key edge. Session remains the sole capture admission and teardown judge.

Presentation handlers queue wire delivery outside the host's binding evaluation. They retain every loss edge and recheck a queued shown edge before granting it. This avoids reading a map binding recursively from its own change handler.

`QQuickWindow.frameSwapped` means queued for presentation. It does not prove the host desktop displays the nested compositor or that a person saw the orb. Render evidence therefore also reads pixels in the orb's actual box.

## Content and input

The orb takes its tone from the current Session phase and mute state. Audio's bounded levels drive its primary and secondary rings. The state line names the phase. One plain-text label draws the words. While a turn collects, it shows Session's partial transcript. Otherwise it shows the service's `transcript` status when its role is `assistant` and its generation is the current conversation's. The status keeps an ended conversation's caption until the next one arrives, so the bubble compares generations itself.

Text longer than `Theme.voiceBubble.textLines` lines shows its last lines, the words said now. The rule holds for the user's partial too: the [plan](../plans/v2-jarvis-plan.md#43-bubble-and-orb) shows both as they arrive and gives no reason to keep a partial's start. Qt elides wrapped text on the right alone ([Text.elide](https://doc.qt.io/qt-6/qml-qtquick-text.html#elide-prop)), so the label holds the whole text and hangs from the bottom of a clipping window. The window is as tall as the text, up to that many of the label's line boxes, and the card follows it.

The bubble adds no transcript producer. Only the duplex engine, [`backend/GptLive.js`](jarvis-live.md), produces assistant captions: Session admits a `transcript` event only while its duplex `speech` region is open. The [chained engine](jarvis-engine.md), the one the daemon starts, calls no transcript port. On the shipped engine the bubble therefore shows no reply words until that producer lands as its own Jarvis item. A duplex engine's user captions and approval controls remain with their assigned owners.

Only Mute and Stop enter `inputItems`. The orb, text, padding and gap between controls pass presses through to the application below. The passive host takes no keyboard focus. Both controls reuse the same service intent as their global shortcuts. Their tooltips read the effective keys, including unbound keys. There is no orb-click action.

## Evidence

- `scripts/test-jarvis-session.js` proves idle refusal, pending demand before capture, shown admission, lost-indicator close and return to idle. Its demand and admission mutations fail the same assertions.
- `scripts/test-jarvis-protocol.js` proves both indicator values and each independent wire refusal, with a mutation per rule.
- `scripts/test-jarvis-daemon.js` supplies only private scripted ports. Without an indicator, retained Talk demand opens no capture. Shown admits it; gone closes it even with an older observed generation. Dropped delivery, ignored loss and identity bypass each fail their owning assertion.
- The desktop-tool fixture retains Talk demand until capture opens, then releases it to create a thinking turn. The daemon suite supplies a delayed indicator and removes this wait in a disposable driver copy. This proves that a tool test cannot assume component creation admitted capture.
- `scripts/smoke/rows/jarvis-bubble.sh` runs within the existing physical-key row's [private world](validation-jarvis.md). It reads bottom-centre geometry, actual orb pixels, no Jarvis widget, continued presentation without a bar, press and release under the orb and gaps, both labelled controls after remapping, focused-output changes, the last three lines of a longer assistant caption with a press passing under its window, no words from an ended conversation, idle unmap, host and screen loss, active daemon death, and disable disposal. Wrong margin, ignored focus, shader-hidden and presentation-bypass controls retain the ordinary readers. Because the chained engine produces no caption, the scripted brain port hands one assistant caption to the daemon's own transcript port directly. The words reader compares the label's box with its clipping window's. A dropped consumer, a fourth line, the first three lines and an ignored generation each fail it. State and presentation poll once per nested IPC round trip. No latency ceiling is claimed.
- The generic layers row proves the optional map request and its ignored-request control. The installed tree contains the same bubble through the install manifest. The read-only-prefix row verifies its files and the stock unconfigured service without a production test switch.

## Omarchy comparison

The read-only Omarchy shell reference's `plugins/osd/Osd.qml` composes a bottom-centred card with an empty input region and no keyboard focus. VGS keeps that passive composition. Its generic host handles reserved space instead of calculating bar clearance in the plugin.

Omarchy's notifications and agents keep service data outside display composition. VGS uses the same boundary but grants no capture from a component's existence or a status file. The service's ordered child wire carries the presented-indicator observation. The bubble's labelled controls use the core's input-item union, because an entirely empty region could not receive their clicks.
