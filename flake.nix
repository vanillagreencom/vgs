{
  description = "VGS, a desktop shell for Hyprland on Quickshell";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      inherit (nixpkgs) lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

      # config/requirements.json is the core's one list of runtime commands;
      # each row names its nixpkgs attribute under packages.nix. A required
      # row without one fails evaluation; an optional row without one stays
      # off the runtime PATH. Quickshell is added because `vgsh run` checks
      # it. Hyprland is not: the session supplies hyprctl.
      requirements = builtins.fromJSON (builtins.readFile ./config/requirements.json);
      runtimePackages = pkgs:
        [ pkgs.quickshell ]
        ++ map
          (row: pkgs.${row.packages.nix or (throw "config/requirements.json: command ${row.command} names no nix package")})
          (builtins.filter (row: !row.optional || row.packages ? nix) requirements);
      runtimePath = pkgs: lib.makeBinPath (runtimePackages pkgs);
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.stdenvNoCC.mkDerivation {
          pname = "vgs";
          version = lib.fileContents ./VERSION;
          src = self;

          nativeBuildInputs = [ pkgs.python3 ];
          # The interpreters fixup writes into the runtime tree's
          # `#!/usr/bin/env` and `#!/bin/bash` lines.
          buildInputs = [ pkgs.bash pkgs.nodejs pkgs.python3 ];

          dontConfigure = true;
          dontBuild = true;

          # The shared installer writes the same tree every channel ships, and
          # $out/bin/vgsh stays its plain link. Hyprland's exec and a
          # single-instance terminal start vgsh and vgsh-tui without the
          # caller's environment, so each bash entry point under bin/ sets the
          # runtime PATH itself: one line after its leading comment block,
          # which the usage text is read from. The line prefixes the runtime
          # path as one unit, and leaves a PATH that already holds it alone.
          installPhase = ''
            runHook preInstall
            DESTDIR= PREFIX=$out bash packaging/install-system.sh
            line='case :$PATH: in *:${runtimePath pkgs}:*) ;; *) PATH=${runtimePath pkgs}''${PATH:+:$PATH} ;; esac; export PATH # vgs-nix-path'
            for entry in $out/share/vgs/bin/*; do
              [[ -f $entry && ! -L $entry ]] || continue
              case "$(head -n 1 "$entry")" in
                '#!/usr/bin/env bash' | '#!/bin/bash') ;;
                *) continue ;;
              esac
              awk -v line="$line" 'NR > 1 && !done && !/^#/ { print line; done = 1 } { print } END { if (!done) print line }' "$entry" >"$entry.nix-path"
              cat "$entry.nix-path" >"$entry"
              rm "$entry.nix-path"
            done
            for entry in vgsh vgsh-tui; do
              grep -qF '# vgs-nix-path' "$out/share/vgs/bin/$entry" || {
                echo "flake: refused: nix-path=missing path=$out/share/vgs/bin/$entry" >&2
                exit 1
              }
            done
            bash scripts/check-install-tree.sh "" "$out"
            runHook postInstall
          '';

          meta = {
            description = "Desktop shell for Hyprland on Quickshell";
            homepage = "https://github.com/vanillagreencom/vgs";
            license = with lib.licenses; [ mit ofl isc ];
            platforms = systems;
            mainProgram = "vgsh";
          };
        };
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.default;
          meta.description = "Run the vgsh command";
        };
      });
    };
}
