{
  description = "nix-aerie: Pre-baked OCI images with Nix + direnv by ETH Library Zurich";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

    nix2container = {
      url = "github:nlewo/nix2container/bb6801be998ba857a62c002cb77ece66b0a57298";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils/11707dc2f618dd54ca8739b309ec4fc024de578b";

    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nix2container, flake-utils, home-manager }:
    # x86_64-linux: Codespaces + GitHub Actions runners (production)
    # aarch64-linux: local testing on Apple Silicon Macs via nix-darwin linux-builder
    flake-utils.lib.eachSystem [ "x86_64-linux" "aarch64-linux" ] (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        n2c = nix2container.packages.${system}.nix2container;
        lib = pkgs.lib;

        # --- Shell definitions (plain Nix functions, not flakes) ---
        pythonShell = import ./shells/python.nix { inherit pkgs; };
        goShell = import ./shells/go.nix { inherit pkgs; };
        javaShell = import ./shells/java.nix { inherit pkgs; };
        k8sShell = import ./shells/k8s.nix { inherit pkgs; };

        # --- Home Manager configuration ---
        homeManagerConfig = home-manager.lib.homeManagerConfiguration {
          inherit pkgs;
          modules = [ ./home.nix ];
        };

        # Wrap Home Manager-generated home-files to place under /home/dev
        homeManagerDotfiles = pkgs.runCommand "home-manager-dotfiles" {} ''
          mkdir -p $out/home/dev
          cp -rLT ${homeManagerConfig.activationPackage}/home-files $out/home/dev/
        '';

        # System-level nix.conf (not managed by Home Manager — it's a system path)
        nixConf = pkgs.writeTextDir "etc/nix/nix.conf" ''
          build-users-group =
          experimental-features = nix-command flakes
          sandbox = false
        '';

        # --- User environment ---
        userPackages = with pkgs; [
          bash
          coreutils
          gitMinimal
          nix
          direnv
          nix-direnv
          curl
          jq
          less
          gnutar
          gzip
          gnugrep
          gnused
          findutils
          xz
          cacert
        ];

        userEnv = pkgs.buildEnv {
          name = "user-env";
          paths = userPackages;
          pathsToLink = [ "/bin" "/etc" "/lib" "/share" ];
        };

        # --- System files: /etc/passwd, /etc/group, directories ---
        systemFiles = pkgs.runCommand "system-files" {} ''
          mkdir -p $out/etc
          mkdir -p $out/home/dev
          mkdir -p $out/workspaces
          mkdir -p $out/tmp

          cat > $out/etc/passwd << 'EOF'
          root:x:0:0:root:/root:/bin/bash
          nobody:x:65534:65534:Nobody:/nonexistent:/usr/sbin/nologin
          dev:x:1000:1000::/home/dev:/bin/bash
          EOF

          cat > $out/etc/group << 'EOF'
          root:x:0:
          nobody:x:65534:
          dev:x:1000:
          EOF
        '';

        # --- Nix profile symlink ---
        nixProfile = pkgs.runCommand "nix-profile" {} ''
          mkdir -p $out/nix/var/nix/profiles
          mkdir -p $out/nix/var/nix/gcroots/profiles
          ln -s ${userEnv} $out/nix/var/nix/profiles/default
        '';

        # --- Wolfi base image (per-architecture digests) ---
        wolfiDigests = {
          "x86_64-linux" = {
            imageDigest = "sha256:a557cd88f9807c3632d2f7978f57b6dcab4ef2358b88aa7b0ae3d2706a44860e";
            sha256 = lib.fakeHash;
          };
          "aarch64-linux" = {
            imageDigest = "sha256:bd736af9ca3fa53ba61622dd50481bd8409e7e8ce57e59fd38e985b7673becde";
            sha256 = "sha256-4rmr+BySon8J/4iLhuXmjXsjROKOSgkReRe2OQBN84Q=";
          };
        };

        wolfiBase = n2c.pullImage {
          imageName = "cgr.dev/chainguard/wolfi-base";
          inherit (wolfiDigests.${system}) imageDigest sha256;
        };

        # --- Shared layers (all variants include these) ---

        # Layer: system files (/etc/passwd, /etc/group, /home/dev, /workspaces)
        systemLayer = n2c.buildLayer {
          copyToRoot = [ systemFiles ];
          metadata.created_by = "nix-aerie: system files (/etc/passwd, /home/dev, /workspaces)";
          perms = [
            {
              path = systemFiles;
              regex = "home/dev";
              mode = "0755";
              uid = 1000;
              gid = 1000;
            }
            {
              path = systemFiles;
              regex = "workspaces";
              mode = "0755";
              uid = 1000;
              gid = 1000;
            }
            {
              path = systemFiles;
              regex = "tmp";
              mode = "1777";
            }
          ];
        };

        # Layer: user packages (nix, bash, git, direnv, etc.)
        userPkgsLayer = n2c.buildLayer {
          deps = [ userEnv ];
          metadata.created_by = "nix-aerie: user packages (nix, bash, git, direnv, coreutils)";
        };

        # Layer: Nix profile (symlink tree)
        nixProfileLayer = n2c.buildLayer {
          copyToRoot = [ nixProfile ];
          metadata.created_by = "nix-aerie: nix profile (/nix/var/nix/profiles/default)";
        };

        # Layer: dotfiles (.bashrc, direnv config, nix.conf)
        dotfilesLayer = n2c.buildLayer {
          copyToRoot = [ homeManagerDotfiles nixConf ];
          metadata.created_by = "nix-aerie: dotfiles (.bashrc, direnv, nix.conf)";
        };

        baseLayers = [
          systemLayer
          userPkgsLayer
          nixProfileLayer
          dotfilesLayer
        ];

        # --- Shell-specific layers ---

        # allShellsLayer: union of all shell closures minus userPkgsLayer.
        # Used only by :full — one layer instead of per-shell deduped layers.
        allShellsLayer = n2c.buildLayer {
          deps = [ pythonShell goShell javaShell k8sShell ];
          layers = [ userPkgsLayer ];
          metadata.created_by = "nix-aerie: all devShell closures (python, go, java, k8s)";
        };

        # Lean shell layers (for individual variants) — exclude only userPkgsLayer.
        # Each carries its full closure minus base packages, nothing from other shells.
        pythonLayer = n2c.buildLayer { deps = [ pythonShell ]; layers = [ userPkgsLayer ]; metadata.created_by = "nix-aerie: python devShell (python312, uv)"; };
        goLayer     = n2c.buildLayer { deps = [ goShell ];     layers = [ userPkgsLayer ]; metadata.created_by = "nix-aerie: go devShell (go, gopls, golangci-lint)"; };
        javaLayer   = n2c.buildLayer { deps = [ javaShell ];   layers = [ userPkgsLayer ]; metadata.created_by = "nix-aerie: java devShell (jdk25, maven)"; };
        k8sLayer    = n2c.buildLayer { deps = [ k8sShell ];    layers = [ userPkgsLayer ]; metadata.created_by = "nix-aerie: k8s devShell (kubectl, helm)"; };

        # --- Image configuration (no User!) ---
        imageConfig = {
          Env = [
            "PATH=/nix/var/nix/profiles/default/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            "NIX_PROFILES=/nix/var/nix/profiles/default"
            "HOME=/home/dev"
            "NIX_SSL_CERT_FILE=/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt"
            "USER=dev"
            "LANG=C.UTF-8"
          ];
          WorkingDir = "/workspaces";
          Cmd = [ "/nix/var/nix/profiles/default/bin/bash" "-l" ];
          Labels = {
            "org.opencontainers.image.title" = "nix-aerie";
            "org.opencontainers.image.description" = "Pre-baked Nix container image by ETH Library Zurich";
            "org.opencontainers.image.source" = "https://github.com/eth-library/nix-aerie";
            "org.opencontainers.image.licenses" = "Apache-2.0";
            "org.opencontainers.image.vendor" = "ETH Library Zurich";
          };
        };

        # --- Variant builder ---
        mkVariant = { name, extraLayers ? [] }:
          n2c.buildImage {
            inherit name;
            fromImage = wolfiBase;
            layers = baseLayers ++ extraLayers;
            config = imageConfig;
            initializeNixDatabase = true;
            nixUid = 1000;
            nixGid = 1000;
          };

      in {
        packages = {
          default = mkVariant {
            name = "nix-aerie";
            extraLayers = [ allShellsLayer ];
          };
          base = mkVariant {
            name = "nix-aerie-base";
          };
          python = mkVariant {
            name = "nix-aerie-python";
            extraLayers = [ pythonLayer ];
          };
          go = mkVariant {
            name = "nix-aerie-go";
            extraLayers = [ goLayer ];
          };
          java = mkVariant {
            name = "nix-aerie-java";
            extraLayers = [ javaLayer ];
          };
          k8s = mkVariant {
            name = "nix-aerie-k8s";
            extraLayers = [ k8sLayer ];
          };
        };

        devShells = {
          python = pythonShell;
          go = goShell;
          java = javaShell;
          k8s = k8sShell;
        };
      }
    );
}
