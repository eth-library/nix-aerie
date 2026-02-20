{ pkgs }:
pkgs.mkShell {
  packages = with pkgs; [
    jdk25_headless
    maven
  ];
}