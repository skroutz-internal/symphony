{
  description = "Symphony Elixir packaged with Nix";

  inputs = {
    nixpkgs.url = "nixpkgs";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f:
        builtins.listToAttrs (map (system: {
          name = system;
          value = f system;
        }) systems);
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          beam = pkgs.beam.packages.erlang_28;

          symphony = beam.mixRelease {
            pname = "symphony";
            version = "0.1.0";
            src = ./elixir;
            elixir = beam.elixir_1_19;

            mixEnv = "prod";
            removeCookie = false;

            mixFodDeps = beam.fetchMixDeps {
              pname = "symphony-mix-deps";
              version = "0.1.0";
              src = ./elixir;
              elixir = beam.elixir_1_19;
              hash = "sha256-JdEnj95ol5raofHmyy18/bx+1akj/K3gxkxAnT1Lk2s=";
            };

            nativeBuildInputs = with pkgs; [ makeWrapper ];

            buildPhase = ''
              runHook preBuild
              mix escript.build
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp bin/symphony $out/bin/symphony
              runHook postInstall
            '';

            postInstall = ''
              wrapProgram $out/bin/symphony \
                --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git beam.erlang ]}
            '';
          };
        in
        {
          default = symphony;
          symphony = symphony;
        });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          beam = pkgs.beam.packages.erlang_28;
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              beam.erlang
              beam.elixir_1_19
              git
            ];
            shellHook = ''
              cd elixir
            '';
          };
        });

      nixosModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.services.symphony;
          pkg = self.packages.${pkgs.system}.default;
        in
        {
          options.services.symphony = {
            enable = lib.mkEnableOption "Symphony orchestrator";

            package = lib.mkOption {
              type = lib.types.package;
              default = pkg;
              defaultText = lib.literalExpression "self.packages.${pkgs.system}.default";
              description = "Symphony package to run.";
            };

            workflowFile = lib.mkOption {
              type = lib.types.path;
              default = "${self}/nix/example-workflow.md";
              defaultText = lib.literalExpression ''"''${self}/nix/example-workflow.md"'';
              description = ''
                Path to the WORKFLOW.md file passed to Symphony.
                See <literal>nix/example-workflow.md</literal> in the Symphony
                repo for a commented reference you can copy and adapt.
              '';
            };

            environmentFile = lib.mkOption {
              type = lib.types.nullOr lib.types.path;
              default = null;
              description = "Optional EnvironmentFile (e.g. LINEAR_API_KEY=...).";
            };

            extraPackages = lib.mkOption {
              type = lib.types.listOf lib.types.package;
              default = [ ];
              description = "Extra runtime packages to place on PATH.";
            };

            user = lib.mkOption {
              type = lib.types.str;
              default = "symphony";
              description = "System user for the service.";
            };

            group = lib.mkOption {
              type = lib.types.str;
              default = "symphony";
              description = "System group for the service.";
            };

            logsRoot = lib.mkOption {
              type = lib.types.path;
              default = "/var/lib/symphony/logs";
              description = "Root directory for Symphony logs.";
            };

            port = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Optional dashboard/API port (passed as --port).";
            };
          };

          config = lib.mkIf cfg.enable {
            users.groups = lib.mkIf (cfg.group == "symphony") {
              symphony = { };
            };

            users.users = lib.mkIf (cfg.user == "symphony") {
              symphony = {
                isSystemUser = true;
                group = cfg.group;
                home = "/var/lib/symphony";
                createHome = true;
              };
            };

            systemd.services.symphony = {
              description = "Symphony Orchestrator";
              wantedBy = [ "multi-user.target" ];
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];

              environment = {
                HOME = "/var/lib/symphony";
              };

              path = cfg.extraPackages;

              serviceConfig = {
                Type = "simple";
                User = cfg.user;
                Group = cfg.group;
                WorkingDirectory = "/var/lib/symphony";
                StateDirectory = "symphony";
                Restart = "on-failure";
                RestartSec = 5;

                ExecStart =
                  let
                    args = [
                      "--i-understand-that-this-will-be-running-without-the-usual-guardrails"
                      "--logs-root" (toString cfg.logsRoot)
                    ]
                    ++ lib.optionals (cfg.port != null) [ "--port" (toString cfg.port) ]
                    ++ [ (toString cfg.workflowFile) ];
                  in
                  lib.escapeShellArgs ([ "${cfg.package}/bin/symphony" ] ++ args);
              } // lib.optionalAttrs (cfg.environmentFile != null) {
                EnvironmentFile = cfg.environmentFile;
              };
            };
          };
        };
    };
}
