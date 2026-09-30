# Jarvis

Jarvis runs a service-owned Node child and shows its health in Settings. The child tracks session state, but this skeleton has no voice control, capture, provider connection or desktop actions.

![The Jarvis daemon's status on its Settings page](../../../docs/images/plugins/vgs.jarvis-page.webp)

Screenshot made with `scripts/readme-shots.sh` in the nested sandbox, with the default theme at scale 2.

## Features

- The child ends when the service closes its stdin.
- Bounded restart reports a problem and shows a toast when recovery ends.
- The service reads the session lock without receiving lock authority.
- The child tracks session state without opening a microphone or a provider.

## Requirements

The daemon needs Node 22 or later. The core's requirement notice offers installation when Node is missing.

## How it works

The service sends its current configuration and lock observation to the child. The child answers with its health and session state. Settings shows its health. Disable destroys the service and its child.

## Settings

This skeleton has no editable settings.
