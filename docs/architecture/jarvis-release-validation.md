# Jarvis release validation

Covers: scripts/test-jarvis-release.js, scripts/test-jarvis-net.js, scripts/fixtures/jarvis/policy.js, scripts/fixtures/jarvis/keys-world.js, scripts/fixtures/jarvis/key-tui.py

The [release and transport contract](jarvis-release.md) defines the installed interface. The [Jarvis test world](validation-jarvis.md) owns isolation.

## Evidence

- `scripts/test-jarvis-release.js` runs the complete label, profile, vision, recipient and grant table. It checks nested summaries, buffer snapshots, markers, immutable recipients and expired grant identities. Its controls remove each independent release rule.
- `scripts/test-jarvis-net.js` uses real HTTP and WebSocket traffic in the [Jarvis test world](validation-jarvis.md). Two origins test key isolation. Redirects test that no second request starts. A socket-creator observer proves that offline refusal occurs before a socket attempt.
- The transport suite tests grants before connection and before frames, safe event targets, localhost pinning, URL refusals, credential metadata, cancellation and owner closure. Its controls mutate disposable code copies, not the installed tree.
- `scripts/validate` selects both suites for their direct and shared inputs. `scripts/test-validate.sh` pins the selection. `packaging/install-tree.manifest` includes the installed network door.
- Normal completion, provider refusal and abrupt disconnect fixtures preserve distinct close outcomes without exposing the socket or provider reason. Controls remove close outcomes or erase the unclean state while keeping close forwarding.
- NUL and pasted Unicode credentials fail safely in both public APIs before any connection. Removing the header setter's safe boundary must break the keyed error and secret-absence assertions.
- The real Add key script and CLI run on the private terminal with scratch secret-tool and presentation stand-ins. Their stored origin and attributes must equal the transport's selected origin. A mutation bypasses endpoint normalization in the producer while leaving storage intact.
- The integration fixture reads the key through the real `Secrets.lookup` API and sends only to the matching loopback origin. Already differently bound references remain refused. No host keyring, authentication or external network enters this fixture.

## Omarchy comparison

The read-only Omarchy shell's agents plugin reads usage records from collectors. Its `omarchy-agent-usage-claude` and `omarchy-agent-usage-fireworks` collectors attach credentials to fixed API requests. VGS keeps network work outside QML. It does not copy their credential-file readers or automatic urllib redirects. Jarvis sends conversation content and supports custom providers, so it needs explicit release consent and exact origin-bound keys.
