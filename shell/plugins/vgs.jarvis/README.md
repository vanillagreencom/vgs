# Jarvis

Jarvis runs a service-owned Node child and shows its health in Settings. The child tracks session state. Jarvis stores provider keys in your desktop keyring. This skeleton has no voice control, capture, provider connection or desktop actions.

![The Jarvis daemon's status on its Settings page](../../../docs/images/plugins/vgs.jarvis-page.webp)

Screenshot made with `scripts/readme-shots.sh` in the nested sandbox, with the default theme at scale 2.

## Features

- The child ends when the service closes its stdin.
- Bounded restart reports a problem and shows a toast when recovery ends.
- The service reads the session lock without receiving lock authority.
- The child tracks session state without opening a microphone or a provider.
- Settings opens Add key in a floating terminal with hidden key input.
- Settings shows whether a referenced key is present, absent, locked or unavailable without reading it.

## Requirements

The daemon needs Node 22 or later. Key storage needs libsecret's secret-tool and a desktop Secret Service. Add key needs gum to draw its terminal header. Key presence needs busctl. The core's requirement notice offers installation of missing commands.

The optional command sandbox needs bubblewrap and available user namespaces. This skeleton offers no shell tools.

## How it works

The service sends its current configuration and lock observation to the child. The child answers with its health and session state. Settings shows its health. Add key asks for a provider, an account label and the provider's origin, then hides key input. The desktop keyring stores the key. VGS stores only the item's reference. Disable destroys the service and its child.

## Settings

This skeleton has no editable settings.

Open Jarvis in Settings and select Add key. Use the provider's origin, such as `https://api.openai.com`, without a path. Add key can ask the desktop keyring to unlock because you started storage. The background presence check never unlocks it.
