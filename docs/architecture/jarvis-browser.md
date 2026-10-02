# Jarvis browser

Covers: shell/plugins/vgs.jarvis/backend/Browser.js, shell/plugins/vgs.jarvis/backend/browser-setup.js, shell/plugins/vgs.jarvis/backend/skills/browser/, shell/plugins/vgs.jarvis/BrowserRuntime.qml, shell/plugins/vgs.jarvis/LocalRuntime.qml, shell/plugins/vgs.jarvis/tui/setup-browser.sh, scripts/test-jarvis-browser.js, scripts/test-jarvis-browser-setup.js, scripts/fixtures/jarvis/browser*, scripts/smoke/rows/jarvis-browser.sh

[D035](../decisions/D035-manifest-requirements.md#jarvis-browser) records the optional driver, vendored stub and executor policy. The [plan's browser contract](../plans/v2-jarvis-plan.md#62-browser) fixes the supported work. The installed driver supplies its core guidance. `Browser.install` adds its ready browser topic to the existing `ComputerHelp` owner and registers that one guidance executor. Installed input help remains available. A brain call to `help` with topic `browser` receives the stub and the cached core guide as its tool result. The real router test proves delivery of both topics. VGS ships only an adapted discovery stub and the upstream Apache-2.0 licence.

## Owners

- `Browser.js` owns the private session, CLI calls, settings file, output and version-specific guidance cache. It registers with the [action router](jarvis-approval.md) only after setup verifies its driver version. Setup completed after daemon start becomes available to the next conversation. Each new private owner requires current verification. The daemon closes it on lease loss or a normal termination signal. Generation changes and conversation end close the current vendor session. A later conversation creates a new one. Cancellation closes the private session and kills its pending CLI call.
- `Tools.js` owns named commands and arguments. It admits no vendor argv or arbitrary selector. Fill text that starts with a dash refuses because the vendor parses global options after subcommands too.
- Every vendor call has a scrubbed environment and neutral configuration. Version probes also have private HOME and working directories because the vendor loads settings before handling its version flag. Browser calls use a random session and namespace. No profile or saved authentication state enters that session.
- The persistent cache keeps only downloaded browser binaries. Each session has a temporary HOME and vendor data. Its browser-cache link points only to those downloads. The temporary session directory also owns policy and configuration files. Closing a session removes that directory and its HOME. Setup stores a readiness marker only after a blank-page read and successful close. Status rejects another driver version. A new verification removes the old marker before opening a browser.
- `LocalRuntime.qml` owns the shared setup status parser and completion refresh. Its browser instance supplies its own status key, TUI name and command. A failed or invalid check replaces ready status. The browser instance opens no browser during a status read.

## Authority and content

The vendor action policy defaults to deny. `Browser.js` owns its allowed and denied action categories. Each action includes content boundaries and an output ceiling. `Tools.js` refuses attachment flags, state loading, cookies, authentication and file URLs through its closed schemas. Model text never becomes a shell command.

Input uses snapshot references. The executor reads the current top-level site, reference role and field type before Policy judges it. It repeats that observation at execution. Password fields refuse. Changed sites and field types refuse. Submit and image controls, and buttons without an explicit non-submit type, become external actions in `Policy.js`.

The router owns conversation-local site grants and turn taint. The executor returns page content with the vendor boundary nonce. `Tools.js` labels browser results `web`. The router taints the live turn. [Policy.release](jarvis-release.md) requires web release consent for remote recipients in the cautious and standard profiles. An offline recipient set still does not authorize browser networking; browser tools must remain unoffered when the future conversation owner selects fully offline mode.

The vendor starts its own daemon. A hard kill of Jarvis cannot call close. The fixed vendor idle timeout then owns eventual shutdown. VGS does not prove immediate vendor teardown after SIGKILL. Its temporary session files then remain until the runtime directory is cleared.

A site grant lets a click run the site's behavior. JavaScript can send data from an ordinary click or fill. The top-level site can embed another origin. The CLI has no atomic field-type guard for fill, so a page can change a field after the last observation. These cases require an active or adversarial page. The grant notice states that Jarvis can act as the user on the site. The observations reduce mistakes but do not confine the site's scripts.

## Setup and distribution

The Settings action and launcher entry open the declared setup TUI from its snapshot. Setup tries a blank-page verification first. Only the vendor's missing-Chrome error offers a download. Download runs only after the user accepts. Setup passes no dependency-install option and changes no desktop configuration.

The manifest declares the driver and Chromium as optional requirements. The core notice installs the driver through AUR or mise. Chromium has package mappings for pacman, apt and dnf. VGS's packages do not bundle either browser program. The installer includes the runtime stub and licence. The recipes and Nix metadata declare the added licence.

## Evidence and comparison

`scripts/test-jarvis-browser.js` runs the real executor and Policy in [J09](validation-jarvis.md). Its driver double follows upstream v0.38.1 JSON fields. It covers raw-flag and file-URL refusals, password fields, site grants, web taint, remote release, submit effects, redirects, bounds, version readiness and missing-driver behavior. Each new refusal and confinement rule has a behavior mutant. Existing router controls prove grant lifetime and approval binding.

`scripts/test-jarvis-daemon.js` also proves that daemon lease loss or SIGTERM closes an owned vendor session and clears its temporary HOME. Its control removes the daemon teardown call.

`scripts/test-jarvis-browser-setup.js` runs the shipped setup script on a private terminal. It covers explicit download consent, verification, failed setup and the installed guidance consumer. The nested browser row uses only a status-process double and an allow-listed TUI fixture. It reads Settings status, setup argv and completion refresh. The shared status reader's controls remove refresh and retain ready after failure.

Omarchy's agents panel opens the default browser in private mode for sign-in. Its browser launcher can hand URLs to an existing browser process. The read-only omarchy-voice browser worker controls existing browser windows. VGS uses a separate driver session because its policy must not inherit the user's signed-in browser. It keeps Omarchy's user-started floating terminal for setup.

Sources: [upstream security](https://agent-browser.dev/security), [v0.38.1 action replies](https://github.com/vercel-labs/agent-browser/blob/v0.38.1/cli/src/native/actions.rs), [v0.38.1 option parsing](https://github.com/vercel-labs/agent-browser/blob/v0.38.1/cli/src/flags.rs), [Quickshell Process](https://quickshell.org/docs/v0.3.1/types/Quickshell.Io/Process/).
