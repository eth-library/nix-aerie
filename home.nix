{ pkgs, ... }:

{
  home.username = "dev";
  home.homeDirectory = "/home/dev";
  home.stateVersion = "25.11";

  programs.bash = {
    enable = true;
    initExtra = ''
      # Source Nix profile — sets NIX_SSL_CERT_FILE and other vars.
      # PATH duplication with container config is harmless and provides
      # a safety net if the container's PATH is modified at runtime.
      if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix.sh ]; then
        . /nix/var/nix/profiles/default/etc/profile.d/nix.sh
      fi
    '';
  };

  programs.direnv = {
    enable = true;
    nix-direnv.enable = true;
    config.global.hide_env_diff = true;
  };
}