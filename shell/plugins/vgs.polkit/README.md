# Polkit

`vgs.polkit` is the session's polkit agent. When an application needs administrator rights, such as `pkexec` or a system settings change, it asks for your password in a dialog drawn in the applied theme.

## Install

The plugin ships with VGS and is enabled by default. polkitd accepts one agent per session, so stop any other polkit agent, such as `hyprpolkitagent` or `polkit-gnome`, from your Hyprland autostart.

## Features

- A dialog over a dimmed screen with the request's message, the account it authenticates as, and the password field.
- Enter or Authenticate submits the password; Escape or Cancel denies the request.
- A wrong password shows the failure and asks again.
- The Settings page shows whether polkitd accepted the agent.

## How it works

1. The shell registers the agent with polkitd while this plugin is enabled.
2. An application asks polkitd for an action; polkitd hands the request to the agent.
3. The plugin shows the dialog on the focused screen. Your password goes to PAM through polkit's helper and is cleared from the field at once.
4. The dialog closes when the request succeeds, fails for good or is cancelled.

When the Settings page reads "Not registered with polkitd", another agent registered first or polkitd is not running. Stop the other agent and restart the shell with `vgsh restart`.
