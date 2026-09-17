# Harness theme tokens

The colour surface Claude Code, Codex and Pi read, and the VGS role that feeds it. The gemini, hermes, omp and opencode targets have no table here: no inventory has been taken from an installed copy of them. Rendering, selection and the diff rules are in [../architecture/agent-cli-themes.md](../architecture/agent-cli-themes.md); the role names are [../architecture/theme.md](../architecture/theme.md).

A role name in the tables below is a key of the map `target_roles` in `bin/vshell_helper.py` emits. The Claude Code and Pi tables list the whole surface of their harness at the version named, so a key with no row is a key that harness does not read. The Codex table lists the scopes VGS writes, not every scope Codex resolves.

Each section states the same five things: the installed version, how the surface was established from that installed copy, the command that regenerates it, how much of the surface VGS writes, and what falls back where VGS writes nothing.

## Claude Code 2.1.273

Source: the six built-in theme tables in the installed binary. Each carries the same 72 keys, and the merge that applies a custom theme keeps only a key the built-in table already has, so the 72 below are the whole surface.

```
strings "$(mise which claude)" | grep -ao '{[^{}]*autoAcceptShimmer:"rgb(208,180,255)"[^{}]*}' \
  | head -1 | grep -o '[a-zA-Z_][a-zA-Z0-9_]*:' | tr -d ':'
```

VGS writes all 72, so no token falls back to a Claude Code default. `claude_theme_overrides` in `bin/vshell_helper.py` owns the values; `CLAUDE_CODE_TOKENS` in `scripts/test-claude-theme.py` holds the key set. `text` is lifted to `CLAUDE_TEXT_CONTRAST` on the background. Every text token reads at `CLAUDE_BODY_CONTRAST` or more on the background, and body text reads at that ratio or more on every fill `BAND_TOKENS` lists; `test_every_contrast_rule_holds_where_the_helper_claims_it` checks both floors. The diff family takes the rules [../architecture/agent-cli-themes.md](../architecture/agent-cli-themes.md) states.

| Token | Fed by |
| --- | --- |
| `text` | `foreground`, lifted to `CLAUDE_TEXT_CONTRAST` on the background |
| `inverseText` | `background` |
| `subtle` | `outline` |
| `inactive` | `bright_black`, or `muted` where `bright_black` is under `CLAUDE_BODY_CONTRAST` on the background |
| `inactiveShimmer` | `bright_black`, or `muted` where `bright_black` is under `CLAUDE_BODY_CONTRAST`, half way to the body text |
| `claude` | `accent` |
| `claudeShimmer` | `accent` one third of the way to the body text |
| `clawd_body` | `accent` |
| `clawd_background` | `background` |
| `briefLabelClaude` | `accent` |
| `rate_limit_fill` | `accent` |
| `rate_limit_empty` | `surfaceContainerHighest` |
| `permission` | `blue` |
| `briefLabelYou` | `blue` |
| `professionalBlue` | `blue` |
| `permissionShimmer` | `bright_blue` |
| `ide` | `bright_blue` |
| `claudeBlue_FOR_SYSTEM_SPINNER` | `blue` |
| `claudeBlueShimmer_FOR_SYSTEM_SPINNER` | `bright_blue` |
| `suggestion` | `bright_cyan` |
| `planMode` | `cyan` |
| `autoAccept` | `magenta` |
| `autoAcceptShimmer` | `bright_magenta` |
| `skill` | `magenta` |
| `merged` | `magenta` |
| `remember` | `magenta` |
| `bashBorder` | `bright_magenta` |
| `effortUltra` | `bright_magenta` |
| `promptBorder` | `outline` |
| `promptBorderShimmer` | `outlineVariant` |
| `success` | `green` |
| `error` | `red` |
| `warning` | `yellow` |
| `warningShimmer` | `bright_yellow` |
| `fastMode` | `bright_red` |
| `fastModeShimmer` | `bright_yellow` |
| `chromeYellow` | `yellow` |
| `diffAdded` | the added hue, at `green`'s chroma |
| `diffRemoved` | the removed hue, at `red`'s chroma |
| `diffAddedDimmed` | the added hue, at `CLAUDE_DIFF_DIMMED_CHROMA` of that chroma |
| `diffRemovedDimmed` | the removed hue, at `CLAUDE_DIFF_DIMMED_CHROMA` of that chroma |
| `diffAddedWord` | the added hue, at `bright_green`'s chroma |
| `diffRemovedWord` | the removed hue, at `bright_red`'s chroma |
| `userMessageBackground` | `surfaceContainer` |
| `userMessageBackgroundHover` | `surfaceContainerHigh` |
| `composerSidebarBackground` | `surfaceContainerLow` |
| `bashMessageBackgroundColor` | `surfaceContainer`'s lightness on `bright_magenta`'s hue |
| `memoryBackgroundColor` | `surfaceContainerHigh`'s lightness on `secondaryContainer`'s hue |
| `selectionBg` | `selection_background` |
| `background` | `background` |
| `red_FOR_SUBAGENTS_ONLY` | `red` |
| `blue_FOR_SUBAGENTS_ONLY` | `blue` |
| `green_FOR_SUBAGENTS_ONLY` | `green` |
| `yellow_FOR_SUBAGENTS_ONLY` | `yellow` |
| `purple_FOR_SUBAGENTS_ONLY` | `magenta` |
| `orange_FOR_SUBAGENTS_ONLY` | `red` and `yellow` in equal parts |
| `pink_FOR_SUBAGENTS_ONLY` | `bright_magenta` |
| `cyan_FOR_SUBAGENTS_ONLY` | `cyan` |
| `rainbow_red` | `red` |
| `rainbow_orange` | `red` and `yellow` in equal parts |
| `rainbow_yellow` | `yellow` |
| `rainbow_green` | `green` |
| `rainbow_blue` | `cyan` |
| `rainbow_indigo` | `blue` |
| `rainbow_violet` | `magenta` |
| `rainbow_red_shimmer` | `bright_red` |
| `rainbow_orange_shimmer` | `bright_red` and `bright_yellow` in equal parts |
| `rainbow_yellow_shimmer` | `bright_yellow` |
| `rainbow_green_shimmer` | `bright_green` |
| `rainbow_blue_shimmer` | `bright_cyan` |
| `rainbow_indigo_shimmer` | `bright_blue` |
| `rainbow_violet_shimmer` | `bright_magenta` |

## Codex 0.154.0

Source: the installed binary's own help text and the `[tui]` field list its configuration parser carries.

```
strings "$(mise which codex)" | grep -o 'animationswhimsy[a-z_]*' | sort -u
strings "$(mise which codex)" | grep -F 'CODEX_HOME/themes/'
```

Codex reads a syntax theme named by `tui.theme` in `~/.codex/config.toml` from `$CODEX_HOME/themes/<name>.tmTheme`. No other `[tui]` key carries a colour: the section's remaining keys are `animations`, `whimsy`, `show_tooltips`, `auto_recap`, `disable_paste_burst`, `question_esc_back`, `raw_output_mode`, `status_line`, `status_line_use_colors`, `terminal_title`, `pet`, `pet_anchor`, `session_picker_view`, `resume_cwd`, `keymap`, `model_availability_nux` and `terminal_resize_reflow_max_rows`, of which `status_line_use_colors` is a switch and not a colour. The rest of the TUI paints in the terminal's own ANSI colours.

No configuration key outside `[tui]` carries a colour either; `NO_COLOR` and `CLICOLOR` are the standard environment switches and name no value. VGS writes the whole tmTheme surface Codex resolves. Codex resolves a scope by longest match and falls back to the theme's global settings entry. VGS writes a foreground for that entry and at least one selector under each scope root `test_codex_theme_paints_every_bundled_theme_readably` in `scripts/check-vshell-helper.py` lists. The test holds roots, not leaves: under `entity`, `storage`, `markup` and `meta` the theme names specific leaves, and a scope outside the selectors below resolves to the global entry, so it paints in `syntaxVariable` rather than from an unset value. The theme's other global settings, among them `background` and `selection`, are left unset: Codex paints code and diffs on the terminal's own background.

| Scope | Fed by |
| --- | --- |
| `(global settings)` | `syntaxVariable` |
| `comment` | `syntaxComment` |
| `string` | `syntaxString` |
| `constant` | `syntaxNumber` |
| `variable` | `syntaxVariable` |
| `keyword, keyword.control, storage.modifier` | `syntaxKeyword` |
| `keyword.operator` | `syntaxOperator` |
| `storage.type, entity.name.type, support, support.type` | `syntaxType` |
| `entity.name.function, entity.name.tag, support.function` | `syntaxFunction` |
| `punctuation` | `syntaxPunctuation` |
| `markup.heading, entity.name.section` | `syntaxHeading` |
| `markup.underline.link` | `syntaxLink` |
| `markup.inserted, diff.inserted` | `syntaxInserted` |
| `markup.deleted, diff.deleted` | `syntaxDeleted` |
| `invalid` | `syntaxDeleted` |
| `entity.other.attribute-name` | `syntaxType` |
| `markup.raw, markup.inline.raw, markup.fenced_code` | `syntaxString` |
| `markup.quote` | `syntaxComment` |
| `markup.list, markup.list.numbered, markup.list.unnumbered` | `syntaxPunctuation` |
| `meta.diff, meta.diff.header, meta.diff.range` | `syntaxHeading` |

## Pi 0.85.1

Source: `theme/theme-schema.json` beside the `pi` executable `mise which pi` names, which closes `colors` to the keys it names and lists the `export` keys separately.

```
jq -r '.properties.colors.properties | keys[]' "$(dirname "$(mise which pi)")/theme/theme-schema.json"
jq -r '.properties.export.properties | keys[]' "$(dirname "$(mise which pi)")/theme/theme-schema.json"
```

VGS writes all 56 colour keys and all 3 HTML-export keys, so none falls back to a Pi default. `PI_COLOR_KEYS` in `scripts/check-vshell-helper.py` holds the key set and `themes/targets/pi-vgs/vgs-theme.json` owns the mapping. Pi's own fallbacks, which VGS no longer reaches: `scrollbarTrack` to `muted`, `scrollbarThumb` to `text`, `searchMatchBg` to `selectedBg`, `searchMatchText` to `text`, `thinkingMax` to `thinkingXhigh`, and each `export` key to a shade derived from `userMessageBg`.

| Key | Fed by | Pi's description |
| --- | --- | --- |
| `accent` | `accent` | Primary accent color (logo, selected items, cursor) |
| `border` | `outline` | Normal borders |
| `borderAccent` | `accent` | Highlighted borders |
| `borderMuted` | `outlineVariant` | Subtle borders |
| `success` | `success` | Success states |
| `error` | `error` | Error states |
| `warning` | `warning` | Warning states |
| `muted` | `muted` | Secondary/dimmed text |
| `dim` | `dim` | Very dimmed text (more subtle than muted) |
| `text` | `foreground` | Default text color (usually empty string) |
| `thinkingText` | `bright_white` | Thinking block text color |
| `selectedBg` | `primaryContainer` | Selected item background |
| `scrollbarTrack` | `outlineVariant` | Fullscreen scrollbar track foreground (falls back to muted when omitted) |
| `scrollbarThumb` | `foreground` | Fullscreen scrollbar thumb foreground (falls back to text when omitted) |
| `searchMatchBg` | `primaryContainer` | Transcript search match background and current-match text (falls back to selectedBg when omitted) |
| `searchMatchText` | `foreground` | Transcript search match text and current-match background (falls back to text when omitted) |
| `userMessageBg` | `accent` | User message background |
| `userMessageText` | `onPrimary` | User message text color |
| `customMessageBg` | `surfaceContainerLow` | Custom message background (hook-injected messages) |
| `customMessageText` | `yellow` | Custom message text color |
| `customMessageLabel` | `accent` | Custom message type label color |
| `toolPendingBg` | `surfaceContainerLow` | Tool execution box (pending state) |
| `toolSuccessBg` | `successContainer` | Tool execution box (success state) |
| `toolErrorBg` | `errorContainer` | Tool execution box (error state) |
| `toolTitle` | `accent` | Tool execution box title color |
| `toolOutput` | `foreground` | Tool execution box output text color |
| `mdHeading` | `magenta` | Markdown heading text |
| `mdLink` | `accent` | Markdown link text |
| `mdLinkUrl` | `muted` | Markdown link URL |
| `mdCode` | `magenta` | Markdown inline code |
| `mdCodeBlock` | `green` | Markdown code block content |
| `mdCodeBlockBorder` | `outlineVariant` | Markdown code block fences |
| `mdQuote` | `bright_white` | Markdown blockquote text |
| `mdQuoteBorder` | `outlineVariant` | Markdown blockquote border |
| `mdHr` | `outlineVariant` | Markdown horizontal rule |
| `mdListBullet` | `accent` | Markdown list bullets/numbers |
| `toolDiffAdded` | `success` | Added lines in tool diffs |
| `toolDiffRemoved` | `error` | Removed lines in tool diffs |
| `toolDiffContext` | `muted` | Context lines in tool diffs |
| `syntaxComment` | `dim` | Syntax highlighting: comments |
| `syntaxKeyword` | `magenta` | Syntax highlighting: keywords |
| `syntaxFunction` | `blue` | Syntax highlighting: function names |
| `syntaxVariable` | `foreground` | Syntax highlighting: variable names |
| `syntaxString` | `green` | Syntax highlighting: string literals |
| `syntaxNumber` | `yellow` | Syntax highlighting: number literals |
| `syntaxType` | `cyan` | Syntax highlighting: type names |
| `syntaxOperator` | `bright_white` | Syntax highlighting: operators |
| `syntaxPunctuation` | `muted` | Syntax highlighting: punctuation |
| `thinkingOff` | `dim` | Thinking level border: off |
| `thinkingMinimal` | `muted` | Thinking level border: minimal |
| `thinkingLow` | `cyan` | Thinking level border: low |
| `thinkingMedium` | `accent` | Thinking level border: medium |
| `thinkingHigh` | `magenta` | Thinking level border: high |
| `thinkingXhigh` | `red` | Thinking level border: xhigh |
| `thinkingMax` | `bright_red` | Thinking level border: max (falls back to thinkingXhigh when omitted) |
| `bashMode` | `success` | Editor border color in bash mode |
| `export.pageBg` | `background` | Page background color |
| `export.cardBg` | `surfaceContainerLow` | Card/container background color |
| `export.infoBg` | `surfaceContainerHigh` | Info sections background (system prompt, notices) |
