{ pkgs }:
let
  packages = with pkgs; [
    python312
    uv
  ];
in {
  inherit packages;
  shell = pkgs.mkShell {
    inherit packages;
    env.LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.stdenv.cc.cc.lib ];
  };
}
