# Jarvis plan: research findings (§ 2)

Companion to [v2-jarvis-plan.md](v2-jarvis-plan.md), split out under the document ceiling. Section numbers are unchanged, so "§ 2.3" and "§ 13" in the plan and the Linear issues still resolve here.

## 2. Research findings

Every claim was read on its primary page on 2026-09-30 unless marked (L = one secondary source).

### 2.1 Hyprland: SUPER + Right Alt (v0.56.2 source; not yet run on a compositor)

- **It binds.** `hl.bind` splits on `+`; a part is a modifier only on an exact upper-case match, so `ALT_R` is a key; `code:<n>` must be lower case [H1]. On press the mask excludes the key's own modifier [H2].
- **Names.** Keysym `SUPER+ALT_R`; keycode `SUPER+code:108` (`<RALT> = 108` in the evdev keycodes), the physical key on every layout, though not behind a key remapper. `hyprlandKey` refuses a colon today (`PluginLogic.js:559`): J01.
- **The keysym fails on two kinds of machine**: an AltGr layout gives `ISO_Level3_Shift`, and the owner's `ctrl:swap_ralt_rctl` gives `Control_R`. Default: `SUPER+code:108`. The owner's input-remapper also turns a tap into F13: Q1.
- **Release is not guaranteed.** A release is matched against the live mask, which includes a released modifier key [H2]. Omarchy's PR #13486 (open) proposes a second bind with `release`, `transparent` and `ignore_mods`. J02 writes it with `non_consuming` and reads press and release in the sandbox.
- **Any Wayland client can press a bind**: a virtual keyboard's key runs binds (`InputManager.cpp` L1623, `runtime-hyprland.md`). §3.7 rests on this.

### 2.2 Speech providers

| Provider | Chosen | Facts |
|---|---|---|
| OpenAI | **GPT-Live-1** (`gpt-live-1`), generally available since 2026-09-10. `wss://api.openai.com/v1/live/sessions`, mono PCM16 24 kHz. `delegation.type = client`; `session.delegation.created`, `session.commentary.append` [V1][V2] | $0.05/min plus the backend; API key only. It "is trained to paraphrase" appended text (500 tokens an append). Audio comes "without timing fields". It listens and speaks at once; stale delegated results are the client's to drop [V3][V4]. No image input. No training use, 30-day abuse log [V5] |
| ElevenLabs | Chained: `scribe_v2_realtime` (`partial_transcript`, `committed_transcript`); speech `eleven_v4_turbo`, `eleven_flash_v2_5` as the cheaper row [V6] | The Agents product is rejected: our brain would need "a public URL using a tunneling tool" [V7]; its client tools need none but make ElevenLabs' model the brain; $0.08/min more [V8] |
| Later | OpenAI `gpt-realtime-2.1`, Google `gemini-3.8-live` | Both fit the duplex shape |

### 2.3 Local speech stack (candidate set; J38 pins it before any other local issue)

The choices are closed by [D066](../decisions/D066-pinned-local-speech-and-bounded-inputs.md). [The artifact declaration](../../shell/plugins/vgs.jarvis/artifacts.json) owns exact files, hashes, runtime builds, inputs and licences. [The actual measurements](../measurements/jarvis-local-2026-09-30.md) include all artifacts, resident tiers, caption costs and bounded Moonshine inputs. The table below remains the research candidate context, not a second pin list.

One Python sidecar on sherpa-onnx (Apache-2.0; it embeds espeak-ng, GPL-3.0, so the user installs the runtime and no VGS package ships it). Wheels: CPU, or `sherpa-onnx==1.13.8+cuda12.cudnn9` [L1].

| Role | Artifact | Facts |
|---|---|---|
| Speech-to-text | `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8` (640 MB) | 25 European languages, CC-BY-4.0. Draft 1's export is an `onnx-asr` layout sherpa-onnx cannot load [L2] |
| Live captions | The same model: a re-decode of the growing buffer at most every 200 ms (sherpa's simulated streaming) | Over budget in J38: `sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-560ms-int8` |
| Other languages | `sherpa-onnx-whisper-turbo` (MIT) | "About 6 GB" VRAM is the PyTorch figure [L3] |
| Small tier | `sherpa-onnx-moonshine-base-en-quantized-2026-02-27` (English, MIT) | Its other languages are non-commercial [L4] |
| Text-to-speech | `kokoro-multi-lang-v1_0` (Apache-2.0) | In sherpa-onnx: English, Chinese, French, Spanish, Italian, Hindi [L5] |
| Other voices | `vits-piper-<locale>-<voice>`, in-process | No `piper` program. Licences differ per voice: only permitted voices are listed [L6] |
| Voice activity | `silero_vad.onnx` (MIT), CPU | [L7] |
| End of turn | `smart-turn-v3.2-cpu.onnx` (BSD-2, 8 MB, 23 languages) | Needs `onnxruntime` and a Whisper feature extractor [L8] |
| Wake word | `sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01`: keywords as text, English only [L9] | The pinned archive's README declares Apache License 2.0: D066 closes Q5. openWakeWord's "hey jarvis" is CC BY-NC-SA; Picovoice has no personal plan [L10] |

- **`artifacts.json`** (J38) pins per artifact: URL, revision, files, SHA-256, runtime version, execution provider, input format, languages, and the licence of software, model and voice. `measure-local` runs a bundled clip through each and records cold load, warm turn, unload, peak memory and speed.
- **Echo cancellation**: PipeWire's `libpipewire-module-echo-cancel`. A module loaded with `pw-cli` lives in that process [P2], so a loader's exit removes it. It holds a microphone stream, so an echo implementation must load it only while capture is open. [J15's implemented half-duplex alternative](../architecture/jarvis-audio-duplex.md#r3-pipewire-module-lifetime) records the documented API limits and answers R3.

**Tiers and admission.** `Hardware.detect()` runs once at setup and is cached (a probe at each start wakes a suspended GPU): CPU flags, RAM, GPU vendor, total VRAM, and whether a CUDA decode of the probe clip succeeds. `Hardware.admit(tier)` runs at every load.

| Tier | Needs | Speech-to-text | Text-to-speech |
|---|---|---|---|
| small | any CPU | Moonshine | a Piper voice |
| medium | 16 GB RAM | Parakeet on CPU | Kokoro on CPU |
| large | NVIDIA, CUDA probe passed | Parakeet on CUDA | Kokoro on CUDA |
| multilingual | with medium or large | plus Whisper turbo | a voice per language |

- **Admission** reads `MemAvailable` and free VRAM (`nvidia-smi`, only when the device's `power/runtime_status` is `active`). A load is admitted when the tier's measured peak plus a 2 GB reserve fits; else the next lower tier; else a spoken and shown refusal. One load at a time. An AMD GPU uses the CPU tiers.
- **Limits.** The sidecar runs in `systemd-run --user --scope` with `MemoryMax` at twice its measured peak and `CPUQuota` at half the cores [L11]. Nothing caps GPU memory: admission is the only guard. With no user manager: a thread cap and `nice`, stated as unenforced.
- Models load at first listen and unload after `unloadMinutes`. The owner's voxtype keeps its own Parakeet loaded and shares no model: Q8.

### 2.4 Inference: what may run on a subscription

One rule: Jarvis stores its own key, or it starts the vendor's unmodified program, which owns its login.

| Provider | Subscription route | Key route | Terms and limits |
|---|---|---|---|
| Anthropic | The installed `claude`: `-p`, stream-json in and out, `--mcp-config --strict-mcp-config`, `--tools ""` [I2] | Messages API | Allowed: "signing in to the unmodified Claude Code binary with their own Claude subscription". Not allowed: offering Claude login, routing plan credentials [I1] |
| OpenAI | `codex app-server`: JSON-RPC on stdio, "experimental"; approvals are server requests; `turn/interrupt` [I3] | Chat Completions | A plan sign-in for open-source apps exists [I4]: Q7 |
| GitHub | `copilot --acp` (public preview). Read-only operations run unasked; tool filters are fixed at start [I5] | BYOK | A brain only with built-in tools excluded. No seat check is documented [I6] |
| Google | None for consumer plans since 2026-06-18; paid API keys still work. Antigravity: third-party access "is a breach" [I7][I8] | Gemini API key, compatible endpoint | Key only |
| OpenRouter, Groq, Cerebras, Mistral | n/a | OpenAI-compatible | xAI marks Chat Completions deprecated [I9]: later |
| Local | n/a | Ollama, llama-server, LM Studio | Tool calling degrades on small models |

- **ACP** v1 (schema 1.23.0): Copilot, Gemini CLI and OpenCode speak it natively; Claude and Codex only through SDK adapters [I10], so they get native drivers.
- **Agent hooks.** `Stop` is a per-turn event in Claude Code and Codex, not task completion. Both offer `PermissionRequest` (allow or deny) and a `Stop` answer `decision: block` whose reason continues the turn [I11][I12]. §7 rests on this.
- **Latency.** No vendor publishes a warm first-token time for its agent program, so the first sound never waits for the brain.
- **Default models** resolve at run time from each provider's list, preferring `claude-sonnet-5-5`, `claude-haiku-4-5`, `gpt-6-luna`, `gemini-3.5-flash-lite`.

### 2.5 omarchy-voice (v0.3.0, MIT)

Taken: `pw-record` and `pw-cat`; a text snapshot of the desktop with each turn; confirmation matched against the daemon's own transcript; bubblewrap around commands; a test that feeds fake frames.

Different: its policy is two regex lists over prose, "not a sandbox or a complete authorization system" by its own `SECURITY.md` (Jarvis: typed effects plus a kernel sandbox); a systemd unit with a polled state file; OpenAI only; a key in an env file; toggle only; barge-in counted at bytes received.

### 2.6 Omarchy (`quattro`)

- Dictation is Voxtype, opt-in, with toggle and push-to-talk binds. Agents are terminal programs behind a per-agent table of flags; no answer returns to the shell.
- **Building toward** (open PRs, none merged): several accounts per agent by `CLAUDE_CONFIG_DIR` or `CODEX_HOME` (#13770); a verified engine, Cohere Transcribe on Vulkan (#13098); packaged plugins with Atreyu, an assistant (#12051).
- **Taken**: toggle and hold together; overlay rules; accounts by environment variable; verify an engine before selecting it. **Different**: Omarchy has no voice-to-agent path, no speech output and no policy.

### 2.7 Sources

[V1] developers.openai.com/api/docs/guides/voice-websockets?api=live · [V2] .../live-delegation · [V3] .../live-conversations · [V4] .../voice-server-controls?api=live · [V5] .../your-data · [V6] elevenlabs.io/docs/overview/models.md · [V7] .../agents-platform/customization/llm/custom-llm.md · [V8] elevenlabs.io/pricing/agents · [I1] code.claude.com/docs/en/legal-and-compliance · [I2] .../cli-reference · [I3] learn.chatgpt.com/docs/app-server · [I4] developers.openai.com/siwc/token-sharing-open-source/codex-app-server · [I5] docs.github.com/en/copilot/how-tos/copilot-cli/use-copilot-cli/allowing-tools · [I6] github.com/github/copilot-sdk · [I7] developers.googleblog.com/an-important-update-transitioning-gemini-cli-to-antigravity-cli · [I8] antigravity.google/terms · [I9] docs.x.ai/developers/model-capabilities/text/comparison · [I10] agentclientprotocol.com/get-started/agents · [I11] code.claude.com/docs/en/hooks · [I12] learn.chatgpt.com/docs/hooks · [I13] libsecret `tool/secret-tool.c` · [B1] github.com/vercel-labs/agent-browser v0.38.1: `SKILL.md`, `security/page.mdx`, `install.rs` · [P1] quickshell.org/docs/v0.3.1/types/Quickshell.Io/Process, `src/io/process.cpp` · [P2] docs.pipewire.org `page_man_pw-cat_1`, `page_man_pw-cli_1`; `pw-cat.c` · [H1] Hyprland v0.56.2 `LuaBindingsToplevel.cpp` L58-109 · [H2] `KeybindManager.cpp` L634-806 · [L1] k2-fsa.github.io/sherpa/onnx/python/install.html · [L2] .../onnx/pretrained_models/offline-transducer/nemo-transducer-models.html; huggingface.co/lwittich/parakeet-tdt-0.6b-v3-onnx-int8-cpu · [L3] github.com/openai/whisper · [L4] .../onnx/moonshine · [L5] github.com/k2-fsa/sherpa-onnx/pull/2303 · [L6] .../onnx/tts/piper.html · [L7] sherpa-onnx issue 3528 · [L8] github.com/pipecat-ai/smart-turn · [L9] .../onnx/kws · [L10] github.com/dscripka/openWakeWord; picovoice.ai/docs/faq/general · [L11] systemd.resource-control(5) · basecamp/omarchy PRs #13486, #13770, #13098, #12051, all open.
