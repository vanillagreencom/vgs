VGS is installed. Void runs runit rather than systemd, so there is no user
service to enable here. Start VGS from your compositor config:

  Hyprland  exec-once = vshell run
  Niri      spawn-at-startup "vshell" "run"

Run vshell deps status to inspect optional feature dependencies. It also
reports which app owns org.freedesktop.Notifications. Void has no
weak-dependency mechanism, so optional tools are not advertised by xbps.

Install python3-Pillow to enable ICC colour profiles.
