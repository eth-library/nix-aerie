{ pkgs }:
pkgs.mkShell {
  packages = with pkgs; [
    python312
    uv
  ];

  env.LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
  ];
}