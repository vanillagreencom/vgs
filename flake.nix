{
  description = "VanillaGreen Shell for Hyprland and Niri";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f system);
    in {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.stdenvNoCC.mkDerivation {
            pname = "vgs-shell";
            version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ./VERSION);
            src = self;
            nativeBuildInputs = [ pkgs.go pkgs.makeWrapper ];
            buildPhase = ''
              runHook preBuild
              export HOME=$TMPDIR
              export GOFLAGS=-mod=vendor
              export CGO_ENABLED=0
              (cd backend && go build -mod=vendor -buildvcs=false -trimpath -ldflags="-s -w -X vshell/backend/internal/registry.cliVersion=$version" -o ../vshell-backend ./cmd/vshell-backend)
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              DESTDIR=$out PREFIX=/usr VGS_BACKEND_BINARY=$PWD/vshell-backend ${pkgs.bash}/bin/bash packaging/install-system.sh
              mkdir -p $out/bin $out/lib/systemd/user
              mv $out/usr/lib/vshell $out/lib/vshell
              mv $out/usr/lib/systemd/user/vshell.service $out/lib/systemd/user/vshell.service
              rm -rf $out/usr
              ln -s ../lib/vshell/bin/vshell $out/bin/vshell
              substituteInPlace $out/lib/systemd/user/vshell.service \
                --replace-fail 'ExecStart=/usr/bin/vshell run' "ExecStart=$out/bin/vshell run"
              wrapProgram $out/lib/vshell/bin/vshell \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.quickshell pkgs.jq pkgs.python3 pkgs.bash ]}
              runHook postInstall
            '';
            meta = {
              description = "VanillaGreen desktop shell for Hyprland and Niri";
              homepage = "https://github.com/vanillagreencom/vgs";
              license = pkgs.lib.licenses.mit;
              platforms = systems;
              mainProgram = "vshell";
            };
          };
        });

      overlays.default = final: prev: {
        vgs-shell = self.packages.${final.system}.default;
      };

      homeManagerModules.default = { config, lib, pkgs, ... }:
        let cfg = config.programs.vgs-shell;
        in {
          options.programs.vgs-shell = {
            enable = lib.mkEnableOption "VanillaGreen Shell";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.system}.default;
            };
          };
          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package pkgs.quickshell pkgs.jq pkgs.python3 ];
            xdg.configFile."quickshell/vshell".source = "${cfg.package}/lib/vshell/quickshell/vshell";
            systemd.user.services.vshell = {
              Unit = {
                Description = "VGS (Hyprland/Niri Quickshell shell)";
                PartOf = [ "graphical-session.target" ];
                After = [ "graphical-session.target" ];
              };
              Service = {
                ExecStart = "${cfg.package}/bin/vshell run";
                Restart = "on-failure";
                RestartSec = 2;
              };
              Install.WantedBy = [ "graphical-session.target" ];
            };
          };
        };
    };
}