# SPDX-FileCopyrightText: 2026 SyoBoN <syobon@syobon.net>
#
# SPDX-License-Identifier: MIT-0

{
  description = "zNES Build Environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        packages = nixpkgs.legacyPackages.${system};
      in
      {
        devShells = {
          build = packages.mkShell {
            buildInputs = with packages; [
              minify
              zig
            ];
          };
          publish = packages.mkShell {
            buildInputs = with packages; [
              wrangler
            ];
          };
        };

        pure = true;
      }
    );
}
