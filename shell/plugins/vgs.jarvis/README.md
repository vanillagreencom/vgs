# Jarvis

Jarvis runs a service-owned Node child and shows its health in Settings. The child tracks session state and saves safety records on your computer. Jarvis stores provider keys in your desktop keyring and finds account login hints. It can verify an API, local or Claude Code account when you request it. The installed daemon has no speech or conversation engine, so nothing calls its desktop and file tools yet.

![The Jarvis daemon's status on its Settings page](../../../docs/images/plugins/vgs.jarvis-page.webp)

Screenshot made with `scripts/readme-shots.sh` in the nested sandbox, with the default theme at scale 2.

## Features

- The child ends when the service closes its stdin.
- Bounded restart reports a problem and shows a toast when recovery ends.
- The service reads the session lock without receiving lock authority.
- The child tracks session state without opening a microphone or a provider.
- Talk mode selects hold or toggle behavior for future engines.
- Mute persists across restarts and blocks talk input.
- A bar icon shows whether Jarvis is off, ready, listening, working, muted or has a problem.
- A click on the bar icon toggles mute, as the Mute key does.
- The child records refused action approvals and privacy cleanup.
- Window, workspace and application tools read each change back from Hyprland before they report it done.
- The listening bubble needs no bar widget. Its orb and text let clicks reach the application below.
- Labelled Mute and Stop buttons use the same actions as their keys.
- File tools list, read, search, write, move and delete files in your home folder. They refuse credential stores, account folders and VGS's own files, and never follow a link out of your home folder.
- Settings opens Add key in a floating terminal with hidden key input.
- Settings shows whether a referenced key is present, absent, locked or unavailable without reading it.
- Settings and the launcher open local voice setup in a floating terminal.
- Local setup verifies downloaded models and runs a bundled test clip without opening audio devices.
- Accounts finds nested account directories and lets you add another directory.
- Accounts can remember a key another tool stored without copying its value.
- Login hints and local-server presence are not verified inference access.
- Jarvis watches its recorded coding tasks and shows how many are running in Settings.
- Stopping a coding task interrupts its agent, escalates until every one of its processes has ended, and only then records it as stopped.
- Desktop tools read and copy clipboard text, play, pause and skip media, set and mute the speaker volume, and show a notification. Screen brightness waits for the Displays plugin's brightness service.
- A clipboard read refuses a copy that a password manager marks as secret, and anything that is not text.
- Screen tools read the screen, a monitor, a window, a region or an area you draw, at most four times a turn and never while the screen is locked.
- Windows of password managers and private browsing are painted black before a screenshot leaves Jarvis. This is limited protection: a title cannot always show private browsing.

- Jarvis prepares a private browser from Set up browser in Settings.

## Requirements

The daemon needs Node 22 or later. Key storage needs libsecret's secret-tool and a desktop Secret Service. Key presence needs busctl. Terminal flows need gum. Local setup needs uv, curl, Python and user namespaces. Its locked wheels target Linux x86_64. A CUDA tier also needs working CUDA libraries. The core's requirement notice offers installation of declared missing commands.

The optional command sandbox needs bubblewrap and available user namespaces. This skeleton offers no shell tools. Opening a file or web link needs gio.

Several coding tasks at once need tmux, which is optional. Without it, a coding task opens in a floating terminal, one task at a time. Task records need flock and Python.

The desktop tools need wl-clipboard, playerctl, WirePlumber and libnotify. The screen tools need grim and ImageMagick 7's magick; drawing an area needs slurp, and screen text for a brain that takes no image needs tesseract. A missing command removes only its own tools; Jarvis finds a newly installed one when it next starts.

## How it works

The service sends its current configuration and lock observation to the child. The child answers with its health and session state. Settings shows its health. Add key asks for a provider, an account label and the provider's origin, then hides key input. The desktop keyring stores the key. VGS stores only the item's reference. Disable destroys the service and its child.

## Coding tasks

No coding agent is connected yet, so Jarvis starts no coding task. It still watches task records on your computer. A task's agent runs in its own process group, inside a private tmux session or the floating terminal. Jarvis checks that the processes are still the task's own before it signals them, and never touches your own tmux sessions. A stop that cannot end every process is reported as a notice and leaves the task running. The Stop key does not stop coding tasks.

## Settings

Task terminal chooses where a coding task opens. Auto uses tmux when it is installed, so several tasks can run at once, and the floating terminal otherwise. Floating opens one task at a time.

Screen to cloud decides whether a screenshot or its text goes to a brain or voice outside your computer: Ask, the default, withholds it unless granted, Allow sends it and Never withholds it. When the brain and the voice both run on your computer, they always receive it. Private windows lists the words that mark a window to paint out, matched in its class or title.

Talk mode defaults to Hold. Toggle keeps conversation demand open until the next press. No mode captures audio until a speech engine is available and the listening bubble has drawn.

Turn on Show in bar on the Jarvis page to put the Jarvis icon in the bar's right section. Its tooltip names the state and what a click does.

Audio uses half duplex. Jarvis closes its microphone while speech plays. Talk can interrupt speech, but spoken interruption during playback is unavailable. Echo cancellation has no supported setting. Jarvis changes no desktop audio defaults.

The Keys section changes Talk, Mute and Stop. Talk defaults to Super with Right Alt. Mute defaults to Super with Shift and Right Alt. Stop defaults to Super with Alt and Period. Mute is separate from Talk mode.

Open Jarvis in Settings and select Add key. Use the provider's origin, such as `https://api.openai.com`, without a path. Add key can ask the desktop keyring to unlock because you started storage. The background presence check never unlocks it.

Select Set up local voice in Settings or the launcher's Jarvis group. Choose a tier in the terminal. Setup downloads its models and a private runtime. Settings reports Ready only after file verification and the bundled probe succeed. This prepares local voice files; voice control is not active in this skeleton.

Brain account keeps the account you select. This skeleton does not start a brain. Settings retains a saved selection when discovery no longer offers it.

Select Accounts to add a directory, choose an existing keyring item by label or inspect login hints. Verify asks for a model and consent because a real inference request may cost money. API and local verification send one small request. A Claude Code account sends one small request through its own installed program, which keeps its login. Other subscriptions and speech-only verification remain unavailable. A login hint never proves inference access.

## Browser

Select Set up browser in Settings or the launcher's Jarvis group. Setup checks an installed browser on a blank page. If no browser is found, it offers a private download. Settings shows readiness after the check succeeds.

The driver needs agent-browser. The requirement notice offers its installation. Browser actions use a private session. Jarvis asks for input access to each site. A site grant lets Jarvis act as you there. Submit actions need confirmation. Password entry remains with you. This skeleton has no connected brain, so browser actions are not active yet.
