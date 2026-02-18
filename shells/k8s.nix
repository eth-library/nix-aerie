{ pkgs }:
pkgs.mkShell {
  packages = with pkgs; [
    kubectl
    kubernetes-helm
  ];
}