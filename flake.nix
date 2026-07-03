{
  description = "agent-store — memory and context store for AI coding agents";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        agent-store = pkgs.rustPlatform.buildRustPackage {
          pname = "agent-store";
          version = "0.1.1";

          src = self;

          cargoLock.lockFile = ./Cargo.lock;

          nativeBuildInputs = [ pkgs.installShellFiles ];

          postInstall = ''
            installManPage man/agent-store.1
            installShellCompletion \
              --bash --name agent-store completions/agent-store.bash \
              --zsh completions/_agent-store \
              --fish completions/agent-store.fish
          '';

          meta = with pkgs.lib; {
            description = "Memory and context store for AI coding agents";
            homepage = "https://github.com/av/agent-store";
            license = licenses.mit;
            mainProgram = "agent-store";
          };
        };
      in
      {
        packages.default = agent-store;
        packages.agent-store = agent-store;

        apps.default = {
          type = "app";
          program = "${agent-store}/bin/agent-store";
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            cargo
            rustc
            clippy
            rustfmt
            rust-analyzer
          ];
        };
      });
}
