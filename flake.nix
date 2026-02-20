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
        skopeo-nix2container = nix2container.packages.${system}.skopeo-nix2container;
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
            sha256 = "sha256-9Ly0cveprDBYb3//yl0zrtwuuF/l7cOUTz1QqNzYSC0=";
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
        # deps ensures all Nix store paths referenced by Home Manager generated scripts
        # (e.g. hm-session-vars.sh, bash-completion) exist in the image.
        # Without deps, `bash -l` fails on missing store paths and VS Code's
        # loginInteractiveShell probe breaks → terminal never opens.
        dotfilesLayer = n2c.buildLayer {
          copyToRoot = [ homeManagerDotfiles nixConf ];
          deps = [ homeManagerDotfiles ];
          layers = [ userPkgsLayer ];
          metadata.created_by = "nix-aerie: dotfiles (.bashrc, direnv, nix.conf)";
          perms = [
            {
              path = homeManagerDotfiles;
              regex = "home/dev";
              mode = "0755";
              uid = 1000;
              gid = 1000;
            }
          ];
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

        # --- Docker-archive builder (produces tar for `docker load`) ---
        # proot: skopeo hardcodes /var/tmp for blob temp files (absent in sandbox)
        mkDockerArchive = { name, tag ? "latest", image }:
          pkgs.runCommand "${name}-docker-archive.tar" {
            nativeBuildInputs = [ skopeo-nix2container pkgs.proot ];
          } ''
            proot -b $TMPDIR:/var/tmp \
              skopeo --insecure-policy copy nix:${image} docker-archive:$out:${name}:${tag}
          '';

      in {
        packages = let
          images = {
            default = mkVariant { name = "nix-aerie"; extraLayers = [ allShellsLayer ]; };
            base    = mkVariant { name = "nix-aerie-base"; };
            python  = mkVariant { name = "nix-aerie-python"; extraLayers = [ pythonLayer ]; };
            go      = mkVariant { name = "nix-aerie-go"; extraLayers = [ goLayer ]; };
            java    = mkVariant { name = "nix-aerie-java"; extraLayers = [ javaLayer ]; };
            k8s     = mkVariant { name = "nix-aerie-k8s"; extraLayers = [ k8sLayer ]; };
          };
        in images // {
          # Docker-archive tars (for `docker load < result`)
          default-tar = mkDockerArchive { name = "nix-aerie"; image = images.default; };
          base-tar    = mkDockerArchive { name = "nix-aerie-base"; image = images.base; };
          python-tar  = mkDockerArchive { name = "nix-aerie-python"; image = images.python; };
          go-tar      = mkDockerArchive { name = "nix-aerie-go"; image = images.go; };
          java-tar    = mkDockerArchive { name = "nix-aerie-java"; image = images.java; };
          k8s-tar     = mkDockerArchive { name = "nix-aerie-k8s"; image = images.k8s; };
        };

        devShells = {
          python = pythonShell;
          go = goShell;
          java = javaShell;
          k8s = k8sShell;
        };

        checks = {
          check-python-shell = pkgs.runCommand "check-python-shell" {} ''
            echo "Checking pythonShell for python3..."
            test -x ${pkgs.python312}/bin/python3
            echo "Checking pythonShell for uv..."
            test -x ${pkgs.uv}/bin/uv
            echo "All python shell checks passed"
            touch $out
          '';

          check-go-shell = pkgs.runCommand "check-go-shell" {} ''
            echo "Checking goShell for go..."
            test -x ${pkgs.go}/bin/go
            echo "Checking goShell for gopls..."
            test -x ${pkgs.gopls}/bin/gopls
            echo "Checking goShell for golangci-lint..."
            test -x ${pkgs.golangci-lint}/bin/golangci-lint
            echo "All go shell checks passed"
            touch $out
          '';

          check-java-shell = pkgs.runCommand "check-java-shell" {} ''
            echo "Checking javaShell for java..."
            test -x ${pkgs.jdk25_headless}/bin/java
            echo "Checking javaShell for mvn..."
            test -x ${pkgs.maven}/bin/mvn
            echo "All java shell checks passed"
            touch $out
          '';

          check-k8s-shell = pkgs.runCommand "check-k8s-shell" {} ''
            echo "Checking k8sShell for kubectl..."
            test -x ${pkgs.kubectl}/bin/kubectl
            echo "Checking k8sShell for helm..."
            test -x ${pkgs.kubernetes-helm}/bin/helm
            echo "All k8s shell checks passed"
            touch $out
          '';

          check-base-tools = pkgs.runCommand "check-base-tools" {
            nativeBuildInputs = [ pkgs.findutils pkgs.gnugrep ];
          } ''
            echo "Checking userEnv for all 15 expected tool binaries..."
            for bin in nix git bash direnv curl jq less tar grep sed find xz gzip ls; do
              echo "  checking $bin..."
              find ${userEnv} -path "*/bin/$bin" \( -type f -o -type l \) | grep -q .
            done
            echo "  checking cacert (SSL CA bundle)..."
            test -e ${userEnv}/etc/ssl/certs/ca-bundle.crt
            echo "All base tool checks passed"
            touch $out
          '';

          check-config-files = pkgs.runCommand "check-config-files" {
            nativeBuildInputs = [ pkgs.gnugrep ];
          } ''
            echo "Checking homeManagerDotfiles for .bashrc content..."
            grep -q "nix.sh" ${homeManagerDotfiles}/home/dev/.bashrc
            grep -q "direnv hook bash" ${homeManagerDotfiles}/home/dev/.bashrc
            echo "Checking nixConf for required nix.conf lines..."
            grep -q "experimental-features = nix-command flakes" ${nixConf}/etc/nix/nix.conf
            grep -q "sandbox = false" ${nixConf}/etc/nix/nix.conf
            grep -q "build-users-group =" ${nixConf}/etc/nix/nix.conf
            echo "All config file checks passed"
            touch $out
          '';
        };
      }
    );
}
