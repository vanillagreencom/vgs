# Jarvis audio

Covers: shell/plugins/vgs.jarvis/backend/Audio.js, shell/plugins/vgs.jarvis/backend/audio-child.py, shell/plugins/vgs.jarvis/backend/jarvisd.js, shell/plugins/vgs.jarvis/Service.qml, scripts/test-jarvis-audio.js, scripts/test-jarvis-audio-daemon.js, scripts/fixtures/jarvis/audio*

`Audio.js::Audio` owns capture, playback, the echo loader and the sidecar audio feed. [D064](../decisions/D064-jarvis-child-lease.md#refined-by-vgs-626-2026-09-30) records the lifetime mechanism. [Jarvis Session](jarvis.md#session) owns admission and retries. Audio uses that judge, not a second lock or mute policy.

## Child lifetime

- Every child starts through `setpriv --pdeathsig KILL`. `audio-child.py::main` checks the expected parent after that signal is installed. A parent that died before installation cannot start an audio command.
- The bootstrap enters a private user and PID namespace through `unshare --map-current-user --pid --fork --kill-child=KILL`. It changes neither the network namespace nor the PipeWire configuration. PipeWire still receives the user's external identity.
- The namespace init owns a daemon-only lease pipe. Audio commands inherit neither that lease nor a provider key. The init ends on lease EOF or command exit. The kernel kills every namespace descendant when init ends, including a detached process that closed its pipes. A process group alone cannot provide this guarantee.
- The inner command also starts through `setpriv --pdeathsig KILL` and checks its expected parent before exec. The readiness pipe proves that this bootstrap ran. Capture's open acknowledgment waits for actual PCM, not process spawn.
- The capture owner exists before its sink or child starts. A provider failure during startup releases that same operation. Late callbacks from a retired sink cannot release a newer capture.
- A player that exits while its provider stream remains open destroys that stream and faults Session. Audio does not wait for another provider frame to read the player exit.
- A daemon killed before the namespace child arms its parent-death signal still closes the lease. Init observes that EOF and ends. `setpriv` alone cannot cover this race or descendants: Linux clears the signal across fork.
- Unprivileged user namespaces are a capture prerequisite. A refusal produces an audio fault. There is no host-process fallback, systemd capture unit, privilege prompt or system configuration change.
- `Audio.teardown(reason, kinds)` is the sole release path. Every caller names its owner kinds. Capture close or failure releases capture and echo only. Playback flush or failure releases playback only. Gate loss releases both, and daemon close also releases discovery. Teardown marks those children as stopping before it closes their leases and audio pipes. It destroys their feeds and waits for their close events. Its acknowledgment follows each named child's `close` event, which includes pipe closure.

[setpriv](https://man7.org/linux/man-pages/man1/setpriv.1.html), [PR_SET_PDEATHSIG](https://man7.org/linux/man-pages/man2/PR_SET_PDEATHSIG.2const.html), [unshare](https://man7.org/linux/man-pages/man1/unshare.1.html) and [PID namespaces](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html) define these Linux mechanisms. [Node's child-process contract](https://nodejs.org/docs/latest-v22.x/api/child_process.html#event-close) defines the close acknowledgment.

## Consumers

| Consumer | Audio interface | Boundary |
|---|---|---|
| Daemon | `capturePort`, `playbackPort`, `observe`, `discover`, `close` | Installed production ports consume Session effects. EOF and protocol or pipe failure close the owner. |
| Session runner | Capture and playback completion or failure callbacks | The runner stamps the originating generation and operation. Late failures cannot alter a newer capture or playback. |
| Service | `devices`, `level` and `audio-fault` wire messages | Declared choices reach Settings through `optionsFrom`. The hidden level reaches the plugin's status record. The service retains an audio fault until daemon restart. Offers alone prove neither capture nor probe recovery. |
| Chained or duplex speech engine | Constructor `captureSink` and `playbackSource` | Supplies a Writable PCM sink and a Readable PCM source. Audio owns their release. The engine owns transcripts and provider disconnects. |
| Echo owner | Constructor `echo.arguments` and `echo.target` | Supplies verified module arguments and its capture target. Audio owns the loader's process and pipe. |

The shipping daemon supplies no speech sink, playback source or echo configuration. Its gate remains unconfigured until the speech engine and mapped indicator exist. Capture collection still belongs to speech. It never returns a successful transcript from an unavailable port.

Playback consumes the speech owner's PCM stream and owns the real `pw-cat` process. [Playback accounting](jarvis-playback.md) defines its pacing, heard-prefix reports and speech-source contract. Echo verification and module parameters remain with the plan's echo-cancellation row. Sidecar protocol and model lifetime remain with the local-adapter row. These later owners must use Audio's existing lifetime, not start a second audio process.

## Device discovery

`Audio.discover` owns one read-only `pw-dump --monitor --no-colors` child. Its bounded incremental JSON reader merges node changes and deletions. Discovery never sets metadata, a default device or a setting.

- Offers use `node.name`, the stable target that `pw-cat` accepts. Transient object ids only identify monitor updates. The cache holds only bounded labels, names and device groups, not arbitrary client properties. Offers sort by that stable name and fit the [choices contract](status.md#setting-choices).
- Empty settings resolve to the first offer at acquisition. An unavailable configured name faults without changing the setting or selecting another device. Device changes apply at the next acquisition.
- A removed active microphone closes capture and the echo loader. Session reports a device-lost fault and allows the plan's three retries. Each retry resolves the same configured selection from current offers. No offers end the retries without starting a microphone.
- Stream properties disable automatic fallback and reconnection. A missing target cannot silently move recording or playback to another device. [WirePlumber's linking contract](https://pipewire.pages.freedesktop.org/wireplumber/policies/linking.html) defines those properties.
- A capture exit can precede the monitor's removal message. Audio closes capture and echo first, then takes one bounded read-only snapshot through the same discovery owner to classify the failure. An explicit new device selection clears only a device-lost fault, not a provider fault.
- Unexpected command exit reports its exit cause. It is not called a lost device. A failed discovery drops offers and faults capture instead of keeping an untrusted list.
- A failed monitor retires through teardown before Audio replaces it. Audio bounds monitor recovery over its own lifetime, including successful monitors that later fail again. The recovery timer stops on daemon close. Exhaustion reports `discovery-recovery-exhausted` and starts no further monitor. This allowance is separate from Session's capture retries. `Audio.retireDiscovery` holds the recovery table; `scripts/test-jarvis-audio.js` proves its bound and cancellation with fixture monitor exits and malformed output.
- Read-only discovery may continue while capture is refused. Daemon lease loss also ends discovery.

[pw-dump](https://docs.pipewire.org/page_man_pw-dump_1.html) defines monitor updates. [pw-cat](https://docs.pipewire.org/page_man_pw-cat_1.html) defines named targets and raw PCM. [pw-cli](https://docs.pipewire.org/page_man_pw-cli_1.html) loads modules in its own local instance, so ending that loader releases its module.

## Buffers and levels

Capture and playback use mono signed 16-bit PCM at 24 kHz. Audio limits each PCM buffer to 64 KiB and closes the affected owner on overflow. Stream backpressure pauses capture or waits for playback's drain. Teardown ends a blocked source or sink.

Levels use root-mean-square sample amplitude, clamped to the wire's range. Each `level` message carries `{ capture, playback }`. The injectable clock permits at most 30 combined reports per second. Playback amplitude describes PCM sent to its pipe, not frames heard. Audio retains no level queue. Discovery limits an unfinished JSON array to 1 MiB and retained nodes to 4096. Diagnostic retention is bounded. The daemon's wire judge bounds each outgoing message. A full outgoing pipe buffer faults and closes the daemon instead of retaining more messages.

These are buffer and protocol limits, not measured latency budgets.

## Requirements and installation

The plugin manifest declares each shipping command under [D035](../decisions/D035-manifest-requirements.md). PipeWire's Arch package provides the audio commands. Debian's [pipewire-bin file list](https://packages.debian.org/trixie/amd64/pipewire-bin/filelist) and Fedora's [pipewire-utils file list](https://packages.fedoraproject.org/pkgs/pipewire/pipewire-utils/fedora-44.html) verify the other package names. The bootstrap uses the already-required Python runtime and util-linux commands. The Arch optional dependency and Fedora required dependency name the audio package. The install manifest includes the owner and bootstrap.

Debian's [util-linux file list](https://packages.debian.org/trixie/amd64/util-linux/filelist) includes setpriv and unshare. Fedora's [util-linux package declaration](https://src.fedoraproject.org/rpms/util-linux/raw/rawhide/f/util-linux.spec) puts setpriv in util-linux and unshare in util-linux-core.

## Evidence

- `scripts/test-jarvis-audio.js` runs real Audio ports through the reducer with synthetic PCM. It proves mute, lock, unknown lock, missing indicator, provider disconnect and lease teardown. Detached descendants hold scratch locks before each trigger. Assertions read lock release before the outer test world ends.
- The same suite proves device offers, retained unavailable ids, monitor removal and recovery, early stream exit, retry bounds, level rate, explicit environment scrubbing, bounded capture and discovery buffers, playback interruption and provider-feed release. Echo-mode overlap cases prove that Session's capture-close and playback-flush effects release independent owners. It includes provider failure during startup and an exited player with a pending provider stream. Mutations break the owning lifetime, recovery, rate, environment, routing and buffer rules.
- `scripts/test-jarvis-audio-daemon.js` instruments disposable daemon copies to supply the later speech and indicator owners. It proves EOF, lock and SIGKILL while real fixture capture is active. A copy without the PID boundary leaves a detached lock held and fails the same assertion. The wrong-parent case pins the bootstrap's startup-race refusal.
- `scripts/test-jarvis-session.js` and `scripts/test-jarvis-session-runner.js` prove failure identity and retries. The protocol suite proves choices and level refusals. The nested Jarvis and read-only-prefix rows read the real service's offers through status. The Jarvis row proves that offers after an audio fault cannot hide that fault, with a control that restores offer-driven success.
- All process tests use the [private Jarvis world](validation-jarvis.md). These lifetime suites use stand-in audio commands. The [playback suite](jarvis-playback.md#evidence) also reads actual audio from a private PipeWire null sink. Auth commands have no executable on the child's PATH.

## Omarchy comparison

The read-only Omarchy shell audio panel uses PipeWire node names for its device list and changes preferred defaults when the user picks one. Jarvis keeps stable names but targets only its own streams. It does not change desktop defaults.

The read-only omarchy-voice reference uses `pw-record`, `pw-cat` and pipe-driven PCM. Jarvis keeps those interfaces. Its audio set instead follows the enabled service's lease. A private PID namespace covers detached descendants that neither a parent-death signal nor a pipe alone can end.
