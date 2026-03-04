{ pkgs }:
let
  packages = with pkgs; [
    go
    gopls
    golangci-lint
  ];
in {
  inherit packages;
  shell = pkgs.mkShell { inherit packages; };
}
