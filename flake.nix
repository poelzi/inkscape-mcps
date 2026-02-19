{
  description = "MCP server for Inkscape CLI and DOM operations";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    opencode = {
      url = "github:anomalyco/opencode/production";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      opencode,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        python = pkgs.python312;

        pythonDeps =
          ps: with ps; [
            fastmcp
            pydantic
            anyio
            filelock
            inkex
            scour
          ];

        devDeps =
          ps: with ps; [
            pytest
            pytest-asyncio
            black
            ruff
            mypy
          ];

        opencode-pkg = opencode.packages.${system}.default;

        inkscape-mcp = python.pkgs.buildPythonApplication {
          pname = "inkscape-mcp";
          version = "0.1.0";
          pyproject = true;

          src = ./.;

          build-system = [ python.pkgs.hatchling ];

          dependencies = pythonDeps python.pkgs;

          nativeCheckInputs = devDeps python.pkgs;

          # scour in nixpkgs is 0.38.x, pyproject.toml pins <0.38 — API compatible
          pythonRelaxDeps = [ "scour" ];

          nativeBuildInputs = [ pkgs.makeWrapper ];

          # inkscape is a runtime dependency — the MCP server shells out to it
          makeWrapperArgs = [
            "--prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.inkscape ]}"
          ];

          meta = {
            description = "MCP server for Inkscape CLI and DOM operations";
            license = pkgs.lib.licenses.mit;
            mainProgram = "inkscape-mcp";
          };
        };

        opencode-inkscape = pkgs.writeShellApplication {
          name = "opencode-inkscape";
          runtimeInputs = [
            opencode-pkg
            pkgs.jq
          ];
          text = ''
            INKS_WORKSPACE="''${1:-''${INKS_WORKSPACE:-$HOME/inkscape-workspace}}"
            shift || true
            export INKS_WORKSPACE
            mkdir -p "$INKS_WORKSPACE"

            OPENCODE_CONFIG="$INKS_WORKSPACE/opencode.json"
            export OPENCODE_CONFIG

            # Build MCP server config with runtime workspace path
            MCP_CONFIG=$(jq -n --arg ws "$INKS_WORKSPACE" '{
              "$schema": "https://opencode.ai/config.json",
              "mcp": {
                "inkscape-mcp": {
                  "type": "local",
                  "command": ["${inkscape-mcp}/bin/inkscape-mcp"],
                  "environment": {
                    "INKS_WORKSPACE": $ws
                  }
                }
              }
            }')

            # Deep-merge with existing config to preserve user settings
            if [ -f "$OPENCODE_CONFIG" ]; then
              jq -s '.[0] * .[1]' "$OPENCODE_CONFIG" - <<< "$MCP_CONFIG" \
                > "$OPENCODE_CONFIG.tmp"
              mv "$OPENCODE_CONFIG.tmp" "$OPENCODE_CONFIG"
            else
              echo "$MCP_CONFIG" > "$OPENCODE_CONFIG"
            fi

            exec opencode "$INKS_WORKSPACE" "$@"
          '';
        };
      in
      {
        packages = {
          default = inkscape-mcp;
          inherit inkscape-mcp opencode-inkscape;
        };

        apps.default = {
          type = "app";
          program = "${inkscape-mcp}/bin/inkscape-mcp";
        };

        apps.opencode = {
          type = "app";
          program = "${opencode-inkscape}/bin/opencode-inkscape";
        };

        devShells.default = pkgs.mkShell {
          packages = [
            (python.withPackages (ps: pythonDeps ps ++ devDeps ps))
            pkgs.inkscape
            pkgs.uv
            pkgs.just
            pkgs.ruff
          ];

          shellHook = ''
            export INKS_WORKSPACE="''${INKS_WORKSPACE:-$HOME/inkscape-workspace}"
            mkdir -p "$INKS_WORKSPACE"
          '';
        };
      }
    );
}
