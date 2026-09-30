# Jarvis

Jarvis runs a service-owned Node child and shows its health in Settings. This skeleton has no voice control, capture, provider connection or desktop actions.

![The Jarvis daemon's status on its Settings page](../../../docs/images/plugins/vgs.jarvis-page.webp)

Screenshot made with `scripts/readme-shots.sh` in the nested sandbox, with the default theme at scale 2.

## Features

- The child ends when the service closes its stdin.
- Bounded restart reports a problem and shows a toast when recovery ends.
- The service reads the session lock without receiving lock authority.

## Requirements

The daemon needs Node 22 or later. The core's requirement notice offers installation when Node is missing.

## How it works

The service sends its current configuration and lock observation to the child. The child answers with its health. Settings shows that answer. Disable destroys the service and its child.

## Settings

This skeleton has no editable settings.
