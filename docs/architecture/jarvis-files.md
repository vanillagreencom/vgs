# Jarvis file tools

Covers: shell/plugins/vgs.jarvis/backend/Files.js, shell/plugins/vgs.jarvis/backend/Anchored.js, scripts/test-jarvis-files.js

The [Jarvis plan § 6](../plans/v2-jarvis-plan.md#6-computer-use-and-browser-reference-set) defines the six file tools: list, read, search, write, move and delete, with Node's `fs` under `Denied.js`. [Policy](jarvis-policy.md) judges each call and [the router](jarvis-approval.md) proposes it after [Audit](jarvis-audit.md). This file defines the executor behind those calls.

## Owners

- `Files.js::create` owns the `files` executor record and its lifetime. `close()` stops a running search at its next folder, and a call after close fails without touching the disk.
- `Files.js::install` registers the record at once and unconditionally, because Node's `fs` needs no probe. A call made while no `Denied` snapshot builds is refused; the next call after a build succeeds works, with no daemon restart.
- `Anchored.js` owns the one anchored descriptor walk. `Accounts.js::directory` uses the same walk for account roots.
- The daemon's `denied()` in `jarvisd.js` is the one producer of the protected path snapshot. It builds `Denied.create` from trusted roots: `HOME`, the XDG config, data and state homes with their defaults, `XDG_RUNTIME_DIR`, the plugin directory the daemon runs from as the install root, and `Accounts.js::accountRoots`. The router's `context()` hands it to Policy as a getter, and Policy reads it only for a call that carries a path, so a window or media call never builds one. This executor calls it again for its rejudge, so each judge sees the current tree.
- A failed build leaves the router's `denied` as `null`, and Policy refuses every path-bearing call as `path-context`, `apps.open` included. No default or empty snapshot stands in. The daemon writes `jarvis: denied=unavailable cause=<key>` to stderr for each failed build the router reads.
- Limitation: `Service.qml` stores any daemon stderr line as its `cause` and then ignores the daemon's output until a restart, so a failed build on a path call stops Jarvis instead of showing a status. The executor names the cause in its result only when its own rejudge's build fails after the router's succeeded.

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
- `files.search` matches the query against names and text lines without case. Matches are listed sorted. A line reads `path:line: text`, cut at `lineChars`. It never follows a link and counts each link it skips. It judges every child with the snapshot before it names, opens or enters it, and skips and counts a protected child. Binary, invalid UTF-8 and over-ceiling files are skipped and counted. The result names the bound that stopped it: entries, bytes, matches or time. Folders past `searchDepth` are counted, not entered.
- `files.write` writes text to a path whose folder exists. An absent folder fails; the tool creates no folder. A target absent at the rejudge is placed with `link`, which fails with `EEXIST` when a file appeared after the judge: that file is never replaced. An existing target must be a regular file. The new file keeps its permission bits and replaces it by `rename`. A path through a link writes the link's target, as `Denied` resolves it.
- `files.move` renames the named entry. A link moves as the link. A move is also judged where it lands (`Denied.inspectPaths`): a folder whose rule-named entry would land within the account name rule's depth refuses `protected-path`, whatever its depth before the move. `EXDEV` fails with a sentence; the tool never copies. A destination absent at the rejudge must still be absent just before the rename. A destination folder that does not exist fails.
- `files.delete` removes a file or a link itself, never a link's target. A folder is walked whole first: every child is judged with role `remove`, no link is followed, and a refusal, the entry ceiling or the depth ceiling refuses the whole call before anything is removed. The tree is then removed bottom-up through held folders. Each entry must still have the inode the walk saw.

An outcome is `completed` only when the read-back sees the effect. A refusal or a failed act is `failed` with a sentence the brain can use, naming the cause by its error code, such as `EACCES`. No raw Node error object reaches a result. An act whose effect could not be read back is `unknown`. A tree removal that stops partway is `failed` and says how many entries it removed.

## Rejudge and the anchored walk

Policy and the router judge each call against a snapshot through `Denied.inspectPaths`. The executor then builds a fresh snapshot and judges every path field again through the same entry. A refusal ends the call `failed` with `Refused: <reason> for <path>`.

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
| `searchSliceEntries` | 64 | entries one search slice handles before it yields |
| `searchSliceMs` | 8 | time one search slice runs before it yields |
| `deleteEntries` | 4096 | entries one tree removal walks |
| `deleteDepth` | 32 | folder levels one tree removal walks |
| `slackMs` | 1000 | scheduling slack added to `timeoutMs` |

These are recovery and resource ceilings for a large tree or file, not measured budgets. `timeoutMs` is `searchMs` plus `slackMs`, the longest path. A search streams each folder through `fs.opendir` on its held descriptor, so the entry ceiling applies before a folder's names load. It works in slices of at most `searchSliceEntries` entries or `searchSliceMs` and yields to the event loop between them, inside one folder as between folders. The slice stays under the playback lead `Audio.js` keeps (`PLAYBACK_LEAD_MS` plus `NODE_LATENCY_MS`). One entry is the longest turn: a file read of at most `readBytes`. No call is cancellable: a write, move or removal cannot be taken back.

## Account name rule

`Denied` protects every `.claude*` and `.codex*` entry one or two levels below HOME, the config home or the data home, by name ([policy](jarvis-policy.md#real-paths)). The rule also covers Claude Code and Codex project folders such as `~/myapp/.claude`, which sit at depth two. Such a folder cannot be read, written, searched, moved or deleted, and its project folder (`~/myapp`) cannot be searched, moved, deleted or used as a workspace. This follows the depth account discovery scans. A rule-named link directly in HOME or an XDG base also protects the folder it points to, such as a dotfile manager's target; one two levels down does not.

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

- `scripts/test-jarvis-files.js` runs the executor in the [J09 world](validation-jarvis.md) on real scratch files. It covers each tool's happy path and read-back, mode keeping, a moved link and removed links and trees. Every tool is refused on credential roots, VGS configuration and state, the install root, rule-named account folders at both counted depths below HOME, the config home and the data home, an explicit account root and a hand-added root. Link escapes refuse for a link out of HOME, a link to a protected folder, a link in a middle component, a dangling link and `..` after a link; the middle-link rows also cover a removal and both fields of a move.
- A file inside a dotfile folder that a `~/.codex*` link points to refuses `protected-path`, with a control. It replays a three-step move sequence that would carry a planted `.claude-x` folder up into the name rule's depth; the last move refuses. Swaps after the judge refuse read, list and search as `path-changed`; swaps between `lstat` and open refuse through `O_NOFOLLOW`, for the walk, the read, the search's files and folders, and a list keeps reading the folder it holds. Faults show the read opens with `O_NONBLOCK`, a write re-checks an existing target before its rename, a removal matches each inode, and a write, move or removal whose read-back does not see the effect answers `unknown`.
- Further cases cover a list that touches no child (no open, read, `opendir` or `stat` of one), the search's skips, each bound, its slices inside one 64-entry folder and its close, a write and a move that never replace an entry that appeared after the judge, a move onto its own entry, a call for another executor, tree removals refused for a protected child, the entry ceiling and the depth ceiling before anything is removed, the binary, invalid UTF-8 and size refusals, `EXDEV`, and unconditional registration that serves a call once a build succeeds. Each rule has its own control.
- The same suite runs a disposable daemon from a plugin copy beside the scratch HOME, so the copy is the daemon's install root and lies outside HOME. `scripts/fixtures/jarvis/desktop-driver.js` routes `files.read` through the real router, Policy, audit and executor. An ordinary file completes with its text. A rule-named account folder, a `CLAUDE_CONFIG_DIR` folder and a hand-added folder whose names the rule does not match, the XDG config home's `vgs` folder and the install root refuse `protected-path`. Controls set the router's `denied` back to `null` (answered `path-context`), drop the account roots, ignore `XDG_CONFIG_HOME` and move the install root; each turns its row red.
