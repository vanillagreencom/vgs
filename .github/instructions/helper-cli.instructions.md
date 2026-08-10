---
applyTo: "bin/**"
---

# Helper CLI

`bin/vshell-helper` is a deliberately single-file, multi-thousand-line Python
CLI (measure it with `wc -l bin/vshell-helper`). Do not
propose splitting it into modules as a review finding — heavy logic living here
rather than in QML is the design. Review it for behavior, not architecture.

Enforce: external tools are exec'd with argv arrays, never a shell string built
from user data; secrets and raw frame payloads are never logged; `bin/vshell`
stays a thin dispatcher.
