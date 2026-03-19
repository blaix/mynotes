{
  description = "MyNotes - A markdown note-taking app";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    ws4sql.url = "github:blaix/ws4sql-nix";
    process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
  };

  outputs = { self, nixpkgs, ws4sql, process-compose-flake }:
    let
      # Support both Mac (development) and Linux (production)
      supportedSystems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      pkgsFor = system: nixpkgs.legacyPackages.${system};

      mkMynotesPackage = system:
        let
          pkgs = pkgsFor system;
          gren = pkgs.gren;
        in
        pkgs.stdenv.mkDerivation {
          pname = "mynotes";
          version = "0.0.1";
          src = ./.;

          buildInputs = [
            gren
            pkgs.nodejs
          ];

          buildPhase = ''
            ${gren}/bin/gren make Main
          '';

          installPhase = ''
            mkdir -p $out/share/mynotes
            cp app $out/share/mynotes/

            # Create wrapper script
            mkdir -p $out/bin
            cat > $out/bin/mynotes <<EOF
#!/bin/sh
cd $out/share/mynotes
exec ${pkgs.nodejs}/bin/node app "\$@"
EOF
            chmod +x $out/bin/mynotes
          '';
        };
    in
    {
      # Packages for all systems
      packages = forAllSystems (system: {
        mynotes = mkMynotesPackage system;
        ws4sql = ws4sql.packages.${system}.default;
        default = mkMynotesPackage system;
      });

      # Development services (process-compose-flake) for all systems
      process-compose = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          mynotes-package = mkMynotesPackage system;
        in
        {
          dev.settings.processes = {
            db = {
              command = ''
                mkdir -p ./data
                echo "Database: ./data/mynotes.db"
                ${ws4sql.packages.${system}.default}/bin/ws4sql --quick-db ./data/mynotes.db
              '';
              ready_log_line = "Web Service listening";
            };

            server = {
              command = ''
                echo "App deployed at: ${mynotes-package}/share/mynotes"
                ${pkgs.nodejs}/bin/node ${mynotes-package}/share/mynotes/app
              '';
              working_dir = "${mynotes-package}/share/mynotes";
              depends_on.db.condition = "process_log_ready";
            };
          };
        }
      );

      # Development shell for all systems
      devShells = forAllSystems (system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              pkgs.gren
              pkgs.nodejs
              pkgs.fd
              ws4sql.packages.${system}.default
            ];

            shellHook = ''
              echo ""
              echo "=================================================="
              echo "Welcome to the mynotes development environment."
              echo "Run 'nix run .#dev' to start services."
              echo "Run 'nix build .#mynotes' to build the package."
              echo "=================================================="
            '';
          };
        }
      );

      # Apps for running development services
      apps = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          processComposeConfig = pkgs.writeText "process-compose.yaml"
            (builtins.toJSON self.process-compose.${system}.dev.settings);
          startScript = pkgs.writeShellScript "start-dev" ''
            # If running in a terminal, use TUI mode, otherwise use log mode
            if [ -t 0 ]; then
              exec ${pkgs.process-compose}/bin/process-compose up -f ${processComposeConfig} --keep-project
            else
              exec ${pkgs.process-compose}/bin/process-compose up -f ${processComposeConfig} --tui=false
            fi
          '';
        in
        {
          dev = {
            type = "app";
            program = "${startScript}";
          };
        }
      );

      # Production NixOS module (Linux only)
      nixosModules.mynotes = { config, lib, pkgs, ... }:
        with lib;
        let
          cfg = config.services.mynotes;
          system = "x86_64-linux";
          mynotes-package = mkMynotesPackage system;
        in
        {
          options.services.mynotes = {
            enable = mkEnableOption "Enable mynotes app service";

            domain = mkOption {
              type = types.str;
              description = "Domain name for the application";
            };

            acmeHost = mkOption {
              type = types.str;
              default = "";
              description = "ACME host to use for SSL certificate (uses useACMEHost instead of enableACME)";
            };

            enableBackups = mkOption {
              type = types.bool;
              default = true;
              description = "Enable automatic daily backups";
            };

            dataDir = mkOption {
              type = types.path;
              default = "/var/lib/mynotes";
              description = "Directory for application data";
            };

            port_ = mkOption {
              type = types.int;
              default = 3001;
              description = "Port for the Node.js application";
            };

            ws4sqlPort = mkOption {
              type = types.int;
              default = 12322;
              description = "Port for the ws4sql database server";
            };

            basicAuthFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              description = "Path to htpasswd file for HTTP Basic auth. Null to disable.";
            };
          };

          config = mkIf cfg.enable {
            # ws4sql database service
            systemd.services.ws4sql-mynotes = {
              description = "ws4sql database server for mynotes";
              wantedBy = [ "multi-user.target" ];

              serviceConfig = {
                ExecStart = "${ws4sql.packages.${system}.default}/bin/ws4sql -port ${toString cfg.ws4sqlPort} --quick-db ${cfg.dataDir}/mynotes.db";
                DynamicUser = true;
                StateDirectory = "mynotes";
                Restart = "always";
                RestartSec = "5s";
              };
            };

            # mynotes application service
            systemd.services.mynotes = {
              description = "MyNotes application";
              wantedBy = [ "multi-user.target" ];
              after = [ "ws4sql-mynotes.service" "network-online.target" ];
              wants = [ "network-online.target" ];
              requires = [ "ws4sql-mynotes.service" ];

              serviceConfig = {
                ExecStart = "${pkgs.nodejs}/bin/node ${mynotes-package}/share/mynotes/app --port ${toString cfg.port_} --ws4sql-port ${toString cfg.ws4sqlPort}";
                WorkingDirectory = "${mynotes-package}/share/mynotes";
                DynamicUser = true;
                User = "mynotes";
                Restart = "always";
                RestartSec = "5s";
              };
            };

            # Optional backup service
            systemd.services.mynotes-backup = mkIf cfg.enableBackups {
              description = "Backup mynotes database";
              serviceConfig = {
                Type = "oneshot";
                ExecStart = pkgs.writeShellScript "mynotes-backup" ''
                  mkdir -p ${cfg.dataDir}/backups
                  ${pkgs.sqlite}/bin/sqlite3 ${cfg.dataDir}/mynotes.db ".backup ${cfg.dataDir}/backups/mynotes-$(date +%Y%m%d-%H%M%S).db"
                  find ${cfg.dataDir}/backups -name "mynotes-*.db" -mtime +60 -delete
                '';
                User = "mynotes";
                DynamicUser = true;
                StateDirectory = "mynotes";
              };
            };

            systemd.timers.mynotes-backup = mkIf cfg.enableBackups {
              description = "Backup timer for mynotes (daily)";
              wantedBy = [ "timers.target" ];
              timerConfig = {
                OnCalendar = "daily";
                Persistent = true;
              };
            };

            # Nginx reverse proxy
            services.nginx = {
              enable = true;
              recommendedProxySettings = true;
              recommendedTlsSettings = true;
              recommendedOptimisation = true;
              recommendedGzipSettings = true;

              virtualHosts.${cfg.domain} = {
                forceSSL = true;
                http2 = false;

                locations."/" = {
                  proxyPass = "http://127.0.0.1:${toString cfg.port_}";
                  proxyWebsockets = true;
                } // lib.optionalAttrs (cfg.basicAuthFile != null) {
                  basicAuthFile = cfg.basicAuthFile;
                };
              } // (if cfg.acmeHost != "" then {
                useACMEHost = cfg.acmeHost;
              } else {
                enableACME = true;
              });
            };
          };
        };

      nixosModules.default = self.nixosModules.mynotes;
    };
}
