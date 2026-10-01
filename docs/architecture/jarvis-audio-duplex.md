# Jarvis half-duplex audio

Covers: shell/plugins/vgs.jarvis/Session.js, shell/plugins/vgs.jarvis/backend/Audio.js, shell/plugins/vgs.jarvis/backend/jarvisd.js, shell/plugins/vgs.jarvis/manifest.json, scripts/test-jarvis-audio.js, scripts/test-jarvis-audio-daemon.js, scripts/test-jarvis-session.js, scripts/test-jarvis-protocol.js

Jarvis uses the half-duplex alternative in [the plan's J15](../plans/v2-jarvis-plan.md#12-issue-breakdown). `Session.canCapture` and `Session.canPlayback` own admission. [Audio](jarvis-audio.md) executes those decisions through its existing leased recorder, player and feeds. It loads no echo module, so no module can retain a microphone after capture closes.

## Admission and resume

- Playback demand closes capture. Playback starts only after Audio acknowledges the recorder and speech feed closed. The same `Session.canPlayback` check controls the reducer's start effect and Audio's acquisition.
- While playback plays or flushes, capture stays closed. There is no microphone data queue to replay after speech. Talk interrupts playback through the existing Session interrupt path.
- Playback completion or flush returns to the same capture admission check. Conversation demand can resume. Released hold demand cannot. Mute, lock, unknown lock, ended lease, absent indicator and provider or device faults cannot reopen capture.
- The wire's `duplex` region reports only `half`. The manifest exposes no echo switch and requires no echo loader command. An extra `echoCancel` setting fails the existing hello settings-shape judge, including when supplied through shell configuration. The service reports the protocol error instead of claiming active echo cancellation.
- The stock daemon installs these real Audio ports. It remains unconfigured until the assigned speech engine and indicator owners exist. Tests supply those interfaces only in disposable copies. Half duplex does not implement an engine, played-frame accounting, wake-word interruption or room echo decay.

## R3: PipeWire module lifetime

The authoritative [pw-cli contract](https://docs.pipewire.org/page_man_pw-cli_1.html) says module loading happens in pw-cli's own local instance, not the remote server. It returns a module variable for local unload. A long-lived loader can therefore own a module without persistent PipeWire configuration. A one-shot invocation exits after its command and cannot retain that owner.

The [echo-cancel contract](https://docs.pipewire.org/page_module_echo_cancel.html) describes microphone capture, an application sink, speaker playback and an echo-cancelled source. It accepts separate properties for those streams. Default-device changes are not a prerequisite: an application can target its own source and sink. Its configuration-file example is not evidence that a persistent file is required.

The [native module API](https://docs.pipewire.org/group__pw__impl__module.html) returns a module or NULL from `pw_context_load_module`. That API can implement checked acquisition in a native client. The existing Node Audio owner uses command-line tools, not a native PipeWire client. The documented pw-cli interface supplies an interactive variable, but no machine-readable load-success or stream-ready acknowledgment. A command write or bootstrap readiness is not proof that cancellation works. Keeping that unchecked path would admit capture while a failed loader remained alive.

R3 is resolved through the permitted half-duplex alternative. VGS removes the unchecked loader rather than parse undocumented interactive output or add a native integration for this item. This is a limitation of the selected integration, not a claim that PipeWire requires persistent configuration. VGS writes no PipeWire configuration and changes no default device. Any future echo implementation must verify both module acquisition and its named source/sink routing before admitting simultaneous capture and playback.

## Evidence

- `scripts/test-jarvis-session.js` proves capture closes before the player start effect, and proves Audio's admission check refuses a player before close acknowledgment. Controls retain those checks but disable each rule. A state-shape control admits `echo` and fails the unsupported-state assertion.
- `scripts/test-jarvis-audio.js` drives real fixture recorder/player processes through Session. It checks recorder absence and closed speech feed during playback. Completion, interrupt and Talk resume permitted demand. Mute, Stop, lock, unknown lock, indicator loss, provider disconnect, speaker removal and lease loss do not. A copy that retains the capture-close call but bypasses its execution fails the same recorder-absence assertion.
- `scripts/test-jarvis-audio-daemon.js` connects synthetic speech ports to disposable copies of the actual daemon. It proves natural resume and mute/lock refusal during speech. EOF and SIGKILL end playback and its detached descendants before the outer private world ends. A Session copy that permits capture during playback fails this daemon path.
- `scripts/test-jarvis-protocol.js` refuses both boolean values of an unsupported echo setting. Its control retains but disables the exact settings-shape check.
- All audio processes run inside `scripts/lib/jarvis-env.sh` against command stand-ins. No real audio endpoint, provider, account or host bus is used. There is no room echo-quality claim or private PipeWire module test because this implementation loads no module.

## Omarchy comparison

The read-only latest Omarchy shell reference uses PipeWire node names in `plugins/panels/audio/Model.js` and changes preferred desktop defaults in `Panel.qml`. Jarvis keeps named stream targets but changes no defaults.

The read-only omarchy-voice reference defaults `barge_in` off in `src/omarchy_voice/config.py`. Its `realtime.py::_mic_loop` drops captured frames while its speaker reports playback. Its Live path sends silence instead. Jarvis uses the same half-duplex policy but ends its recorder and speech feed before starting playback. This keeps privacy lifetime with the enabled service and avoids a continuously open microphone during speech.
