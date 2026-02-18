{ pkgs }:
pkgs.mkShell {
  packages = with pkgs; [
    go
    gopls
    golangci-lint
  ];
}