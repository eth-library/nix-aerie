{ pkgs }:
let
  packages = [
    pkgs.jdk25_headless
    (pkgs.maven.override { jdk_headless = pkgs.jdk25_headless; })
  ];
in {
  inherit packages;
  shell = pkgs.mkShell { inherit packages; };
}
