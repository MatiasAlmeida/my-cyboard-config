{
  description = "ZMK firmware for the Cyboard Imprint: a dev shell to build it locally";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

    # ZMK v0.3.0 builds on Zephyr 3.5 (zmkfirmware/zephyr v3.5.0+zmk-fixes):
    # zephyr-nix reads the Python requirements of west and the build from it.
    zephyr.url = "github:zephyrproject-rtos/zephyr/v3.5.0";
    zephyr.flake = false;

    zephyr-nix.url = "github:nix-community/zephyr-nix";
    zephyr-nix.inputs.nixpkgs.follows = "nixpkgs";
    zephyr-nix.inputs.zephyr.follows = "zephyr";
  };

  outputs =
    { nixpkgs, zephyr, zephyr-nix, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      zephyrPkgs = zephyr-nix.lib.mkZephyr {
        inherit pkgs;
        zephyr-src = zephyr;
      };

      # Builds the firmware like ZMK's GitHub Actions workflow
      # (build-user-config.yml at v0.3.0, build.yaml here): since this repo has
      # a zephyr/module.yml, the west workspace lives outside it (its own
      # zephyr/ would clash with the Zephyr checkout), the keymap is read
      # from config/, and the repo is an extra module. The workspace is a
      # cache, fetched again after a change to config/west.yml. ZMK finds
      # Zephyr with find_package(Zephyr HINTS ../zephyr), which CI satisfies
      # with `west zephyr-export` (a CMake registry entry in ~/.cmake); here
      # Zephyr_DIR points at it instead. The .uf2 files get the CI
      # artifacts' names, in build/.
      zmkBuild = pkgs.writeShellApplication {
        name = "zmk-build";
        runtimeInputs = with pkgs; [ coreutils git ];
        text = ''
          side=''${1:-all}
          case $side in
            left | right) sides=("$side") ;;
            all) sides=(left right) ;;
            *)
              echo "usage: zmk-build [left|right|all]" >&2
              exit 2
              ;;
          esac
          repo=$(git rev-parse --show-toplevel)
          ws=''${ZMK_WORKSPACE:-''${XDG_CACHE_HOME:-$HOME/.cache}/zmk/$(basename "$repo")}
          stamp="$ws/.west-manifest.sha256"
          want=$(sha256sum <"$repo/config/west.yml" | cut -d' ' -f1)
          mkdir -p "$ws/config"
          if [ "$(cat "$stamp" 2>/dev/null || true)" != "$want" ]; then
            cp "$repo/config/west.yml" "$ws/config/west.yml"
            [ -d "$ws/.west" ] || (cd "$ws" && west init -l config)
            (cd "$ws" && west update --fetch-opt=--filter=tree:0)
            echo "$want" >"$stamp"
          fi
          for s in "''${sides[@]}"; do
            (cd "$ws" && west build -p auto -s zmk/app -d "$repo/build/$s" -b assimilator-bt -- \
              -DSHIELD="imprint_$s" -DZMK_CONFIG="$repo/config" -DZMK_EXTRA_MODULES="$repo" \
              -DZephyr_DIR="$ws/zephyr/share/zephyr-package/cmake")
            cp "$repo/build/$s/zephyr/zmk.uf2" "$repo/build/imprint_$s-assimilator-bt-zmk.uf2"
            echo "zmk-build: $repo/build/imprint_$s-assimilator-bt-zmk.uf2"
          done
        '';
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          # Zephyr SDK 0.16 (0.16.9), the series ZMK's build image uses for
          # Zephyr 3.5; only the ARM toolchain (the nRF52840).
          (zephyrPkgs.sdks."0_16".sdk.override { targets = [ "arm-zephyr-eabi" ]; })
          zephyrPkgs.pythonEnv
          pkgs.cmake
          pkgs.ninja
          pkgs.dtc
          pkgs.git
          zmkBuild
        ];
      };
    };
}
