{ pkgs }:
let
  packages = with pkgs; [
    kubectl
    kubernetes-helm
  ];
in {
  inherit packages;
  shell = pkgs.mkShell { inherit packages; };
}
