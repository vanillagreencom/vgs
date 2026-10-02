# Shell tools

- `shell.argv` receives `argv`, an absolute `cwd` inside an ordinary HOME workspace, and the required boolean `network`.
- `shell.line` receives `line`, the same `cwd` and `network`. It sends the exact text to `/bin/sh -c` inside the same sandbox. Shell syntax grants no permission.
- Tools appear only after kernel confinement and protected-path discovery succeed. There is no command fallback.
- The tool table owns read-only argv classification. Shell lines and wrappers remain execution actions. Requested networking needs external approval in every policy profile.
- The working directory is writable. HOME elsewhere is read-only. Credential stores, VGS and Jarvis configuration and state stay masked. Desktop, bus, audio, input and keyring endpoints stay absent. Privilege elevation cannot grant authority.
- The kernel owner bounds execution and combined stdout and stderr. It ends the namespace on cancellation, timeout or output overflow. A stopped result has an unknown outcome. A nonzero command status fails.
- Results carry the command source label. Output is untrusted context. The outbound release judge must approve its recipients before sending it to a provider.
