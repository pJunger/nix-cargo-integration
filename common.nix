{ memberName
, buildPlatform
, cargoToml
, workspaceMetadata
, sources
, system
, root
, overrides
}:
let
  edition = cargoToml.edition or "2018";
  cargoPkg = cargoToml.package;
  bins = cargoToml.bin or [ ];
  autobins = cargoPkg.autobins or (edition == "2018");
  isCrate2Nix = buildPlatform == "crate2nix";

  srcs = sources // (
    (overrides.sources or (_: _: { }))
      { inherit system cargoPkg bins autobins workspaceMetadata root memberName buildPlatform; }
      sources);

  packageMetadata = cargoPkg.metadata.nix or null;

  rustOverlay = import srcs.rustOverlay;
  devshellOverlay = import (srcs.devshell + "/overlay.nix");

  basePkgsConfig = {
    inherit system;
    overlays = [
      rustOverlay
      devshellOverlay
      (final: prev:
        let
          rustToolchainFile = root + "/rust-toolchain";
          baseRustToolchain =
            if builtins.pathExists rustToolchainFile
            then prev.rust-bin.fromRustupToolchainFile rustToolchainFile
            else prev.rust-bin."${workspaceMetadata.toolchain or "stable"}".latest.default;
          toolchain = baseRustToolchain.override {
            extensions = [ "rust-src" "rustfmt" "clippy" ];
          };
        in
        {
          rustc = toolchain;
          rustfmt = toolchain;
        } // (prev.lib.optionalAttrs isCrate2Nix {
          cargo = toolchain;
          clippy = toolchain;
        })
      )
    ] ++ (
      if buildPlatform == "naersk"
      then [
        (final: prev: {
          naersk = prev.callPackage srcs.naersk { };
        })
      ]
      else if isCrate2Nix
      then [
        (final: prev: {
          crate2nixTools = import "${srcs.crate2nix}/tools.nix" { pkgs = prev; };
        })
      ]
      else throw "invalid build platform: ${buildPlatform}"
    );
  };
  pkgs = import srcs.nixpkgs (basePkgsConfig // (
    (overrides.pkgs or (_: _: { }))
      { inherit system cargoPkg bins autobins workspaceMetadata root memberName sources buildPlatform; }
      basePkgsConfig));

  # courtesy of devshell
  resolveToPkg = key:
    let
      attrs = builtins.filter builtins.isString (builtins.split "\\." key);
      op = sum: attr: sum.${attr} or (throw "package \"${key}\" not found");
    in
    builtins.foldl' op pkgs attrs;
  resolveToPkgs = map resolveToPkg;

  baseConfig = {
    inherit pkgs cargoPkg bins autobins workspaceMetadata packageMetadata root system memberName buildPlatform;
    sources = srcs;

    # Libraries that will be put in $LD_LIBRARY_PATH
    runtimeLibs = resolveToPkgs ((workspaceMetadata.runtimeLibs or [ ]) ++ (packageMetadata.runtimeLibs or [ ]));
    buildInputs = resolveToPkgs ((workspaceMetadata.buildInputs or [ ]) ++ (packageMetadata.buildInputs or [ ]));
    nativeBuildInputs = resolveToPkgs ((workspaceMetadata.nativeBuildInputs or [ ]) ++ (packageMetadata.nativeBuildInputs or [ ]));
    env = (workspaceMetadata.env or { }) // (packageMetadata.env or { });

    overrides = {
      shell = overrides.shell or (_: _: { });
      build = overrides.build or (_: _: { });
    } // pkgs.lib.optionalAttrs isCrate2Nix {
      mainBuild = overrides.mainBuild or (_: _: { });
    };
  } // pkgs.lib.optionalAttrs isCrate2Nix {
    crateOverrides = (import ./extraCrateOverrides.nix { inherit pkgs; }) // (
      pkgs.lib.foldAttrs
        pkgs.lib.recursiveUpdate
        { }
        (
          builtins.map
            (crate: {
              ${crate.name} = prev: {
                nativeBuildInputs = (prev.nativeBuildInputs or [ ]) ++ (resolveToPkgs crate.nativeBuildInputs);
                buildInputs = (prev.buildInputs or [ ]) ++ (resolveToPkgs crate.buildInputs);
              } // (
                pkgs.lib.filterAttrs
                  (name: _: name != "nativeBuildInputs" || name != "buildInputs" || name != "name")
                  crate
              );
            })
            ((workspaceMetadata.crateOverride or [ ]) ++ (packageMetadata.crateOverride or [ ]))
        )
    );
  };
in
(baseConfig // ((overrides.common or (_: { })) baseConfig))
