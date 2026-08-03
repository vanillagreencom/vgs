VGS installs the user service but does not enable it automatically.
Start it for the current user with:

  systemctl --user enable --now vshell.service

Run vshell deps status to inspect optional feature dependencies. Void has no
weak-dependency mechanism, so optional tools are not advertised by xbps.
