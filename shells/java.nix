{ pkgs }:
pkgs.mkShell {
  packages = [
    pkgs.jdk25_headless
    (pkgs.maven.override { jdk_headless = pkgs.jdk25_headless; })
  ];
}