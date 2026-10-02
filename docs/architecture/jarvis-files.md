# Jarvis file tools

Covers: shell/plugins/vgs.jarvis/backend/Files.js, shell/plugins/vgs.jarvis/backend/Anchored.js, scripts/test-jarvis-files.js

The [Jarvis plan § 6](../plans/v2-jarvis-plan.md#6-computer-use-and-browser-reference-set) defines the six file tools: list, read, search, write, move and delete, with Node's `fs` under `Denied.js`. [Policy](jarvis-policy.md) judges each call and [the router](jarvis-approval.md) proposes it after [Audit](jarvis-audit.md). This file defines the executor behind those calls.

## Owners

- `Files.js::create` owns the `files` executor record and its lifetime. `close()` stops a running search at its next folder, and a call after close fails without touching the disk.
- `Files.js::install` registers the record at once, because Node's `fs` needs no probe, but only when one `Denied` snapshot builds. Without it the router offers no file tool, as it offers no tool whose command is missing.
- `Anchored.js` owns the one anchored descriptor walk. `Accounts.js::directory` uses the same walk for account roots.
- The daemon's `denied()` in `jarvisd.js` is the one producer of the protected path snapshot. It builds `Denied.create` from trusted roots: `HOME`, the XDG config, data and state homes with their defaults, `XDG_RUNTIME_DIR`, the `--tree` install root and `Accounts.js::accountRoots`. The router's `context()` and this executor each call it for every judge, so each judge sees the current tree.
- A failed build leaves the router's `denied` as `null`, and Policy refuses every path-bearing call as `path-context`, `apps.open` included. No default or empty snapshot stands in. The service treats every daemon stderr line as the daemon's fatal cause (`Service.qml`), so the build failure writes no stderr line. The executor's own rejudge names the cause in its result.

The daemon's lease closes the executor after the router.

## Tools

`Tools.TABLE` owns each row's arguments, effect, executor and path roles. The executor reads the roles from `Tools.refine(call).paths` and keeps no second list.

| Tool | Act | Read back as completed |
|---|---|---|
| `files.list` | the folder's entries, one level, sorted by name | the listing itself |
| `files.read` | one regular file as UTF-8 text | the text itself |
| `files.search` | names and text lines under a folder | the matches and skip counts |
| `files.write` | a temporary file in the target's folder, then a no-replace link or a rename | size, SHA-256 prefix and mode of the file read again |
| `files.move` | one rename between held folders | source absent and destination present |
| `files.delete` | a file, a link or a whole folder tree | the path is absent |

- `files.list` names each entry with its kind (`file`, `directory`, `link` or `other`) and the size of a regular file. It reads metadata only: no child is opened and no link is followed. A list past `listEntries` says so.
- `files.read` refuses a folder, fifo, socket or device before any open. It opens the file with `O_NONBLOCK`, so a fifo swapped in after the check cannot block. A file over `readBytes`, a file holding NUL and a file that is not valid UTF-8 fail with their size; the text is not returned. The router clips every result at 16 KiB; `readBytes` bounds memory.
- `files.search` matches the query against names and text lines without case. A line reads `path:line: text`, cut at `lineChars`. It never follows a link and counts each link it skips. It judges every child with the snapshot before it names, opens or enters it, and skips and counts a protected child. Binary, invalid UTF-8 and over-ceiling files are skipped and counted. The result names the bound that stopped it: entries, bytes, matches or time. Folders past `searchDepth` are counted, not entered.
- `files.write` writes text to a path whose folder exists. An absent folder fails; the tool creates no folder. A target absent at the rejudge is placed with `link`, which fails with `EEXIST` when a file appeared after the judge: that file is never replaced. An existing target must be a regular file. The new file keeps its permission bits and replaces it by `rename`. A path through a link writes the link's target, as `Denied` resolves it.
- `files.move` renames the named entry. A link moves as the link. `EXDEV` fails with a sentence; the tool never copies. A destination absent at the rejudge must still be absent just before the rename. A destination folder that does not exist fails.
- `files.delete` removes a file or a link itself, never a link's target. A folder is walked whole first: every child is judged with role `remove`, no link is followed, and a refusal, the entry ceiling or the depth ceiling refuses the whole call before anything is removed. The tree is then removed bottom-up through held folders. Each entry must still have the inode the walk saw.

An outcome is `completed` only when the read-back sees the effect. A refusal or a failed act is `failed` with a sentence the brain can use, naming the cause by its error code, such as `EACCES`. No raw Node error object reaches a result. An act whose effect could not be read back is `unknown`. A tree removal that stops partway is `failed` and says how many entries it removed.

## Rejudge and the anchored walk

Policy and the router judge each call against a snapshot. The executor then builds a fresh snapshot and judges every path field again with its role. A refusal ends the call `failed` with `Refused: <reason> for <path>`.

The router's `start` rejudges, `Audit.before` is synchronous, and list, read, write, move and delete are synchronous. Those acts therefore run in the same event-loop turn as both rejudges. The search is asynchronous, so it judges each child with the snapshot it started with; the name rule below still judges a child created after that snapshot.

The executor never opens a path by its string. `Anchored.directory` opens `/` and then each component with `O_DIRECTORY | O_NOFOLLOW`, holding the parent's descriptor. Each later open uses the Linux path `/proc/self/fd/<fd>/<name>`, which resolves through the held inode. A component that became a link, vanished or changed kind after the judge refuses as `path-changed`. A final entry opens with `O_NOFOLLOW`; an `lstat` of the same name decides its kind first. A rename that moves a held folder elsewhere cannot redirect the walk outside that folder.

`Denied.inspect` judges a move source and a removal as the named entry: a final link is judged as the link, so removing a link to a protected folder is permitted and never touches the folder.

## Bounds

| Bound | Value | Meaning |
|---|---|---|
| `listEntries` | 512 | names one list returns |
| `readBytes` | 1 MiB | one file read, and one file a search reads |
| `writeBytes` | 1 MiB | one write's text |
| `searchDepth` | 8 | folder levels a search enters below its folder |
| `searchEntries` | 20000 | entries one search visits |
| `searchBytes` | 16 MiB | file bytes one search reads |
| `searchMatches` | 100 | matches one search returns |
| `lineChars` | 200 | characters of one matching line |
| `searchMs` | 10000 | one search's wall time |
| `deleteEntries` | 4096 | entries one tree removal walks |
| `deleteDepth` | 32 | folder levels one tree removal walks |
| `slackMs` | 1000 | scheduling slack added to `timeoutMs` |

These are recovery and resource ceilings for a large tree or file, not measured budgets. `timeoutMs` is `searchMs` plus `slackMs`, the longest path. The search checks its wall time before each entry and yields to the event loop between folders, so the daemon's audio pacing keeps running. No call is cancellable: a write, move or removal cannot be taken back.

## Release labels and taint

`files.list`, `files.read` and `files.search` carry source `file` in `Tools.TABLE`. A file name is content an outside party can choose, as the plan's [§ 3.8](../plans/v2-jarvis-plan.md#38-release-gate-what-leaves-the-machine) labels it. The router taints the turn when a `file` result reaches it, and the [release gate](jarvis-release.md) withholds it from a cloud recipient as `[withheld: file text]` until the user grants it. Write, move and delete results carry no source label.

## Residual races

- Between the executor's rejudge and its act, a same-user process can rename an entry within a held folder. The act then works on whatever entry holds that name in that folder. It cannot reach a path outside the folder the judge saw.
- A move's destination check and its rename are two system calls. A destination created between them is replaced. Node offers no `renameat2` with `RENAME_NOREPLACE`.
- A write to an existing file checks the target is a regular file just before its rename. A link created in between is itself replaced, never followed.
- A file system without hard links fails a new write with the `link` error code.
- A search judges every child against the snapshot it started with. It follows no link, so an alias of a protected root made during the search is skipped as a link, and a rule-named account entry made during it is still judged by name.

## Omarchy comparison

Omarchy's shell (basecamp/omarchy `c05d901`) has no agent file tool. Its `agents` plugin only reads usage records. VGS therefore has no Omarchy approach to adopt here.

## Evidence

- `scripts/test-jarvis-files.js` runs the executor in the [J09 world](validation-jarvis.md) on real scratch files. It covers each tool's happy path and read-back, mode keeping, a moved link and removed links and trees. Every tool is refused on credential roots, VGS configuration and state, the install root, rule-named account folders at both counted depths below HOME, the config home and the data home, an explicit account root and a hand-added root. Link escapes refuse for a link out of HOME, a link to a protected folder, a link in a middle component, a dangling link and `..` after a link. Swaps after the judge and between `lstat` and open refuse as `path-changed`. Further cases cover a list that opens no child, the search's skips and each bound, its yield and close, a write and a move that never replace an entry that appeared after the judge, a tree removal refused before anything is removed, the binary and size refusals, `EXDEV` and registration.
- Controls remove the rejudge, the snapshot failure, `O_NOFOLLOW` in the walk and on the final entry, the anchored parent, the final link check, the list's metadata-only rule, link skipping and `O_NOFOLLOW` in the search, the per-child judge, the binary check, the read ceiling, each search bound, the yield, the close stop, the closed start, the no-replace link, mode keeping, the move destination check, the walk-first removal, the removal's per-child judge and entry ceiling, registration and the `EXDEV` sentence.
- The same suite runs one disposable daemon from a minimal VGS tree copy beside the scratch HOME, since the checkout holding HOME is the daemon's install root. `scripts/fixtures/jarvis/desktop-driver.js` routes `files.read` through the real router, Policy, audit and executor. An ordinary file completes with its text; a rule-named account folder refuses `protected-path`. A control sets the router's `denied` back to `null` and must turn red.
