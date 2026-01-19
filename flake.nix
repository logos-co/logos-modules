{
  description = "Logos Modules - Build system for creating LGX packages";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    logos-package.url = "github:logos-co/logos-package";
  };

  outputs = { self, nixpkgs, logos-package }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f {
        pkgs = import nixpkgs { inherit system; };
        lgxPackage = logos-package.packages.${system}.lgx;
      });
    in
    {
      packages = forAllSystems ({ pkgs, lgxPackage }: {
        # Expose the lgx binary from logos-package
        lgx = lgxPackage;
        
        # Default package
        default = lgxPackage;
      });

      devShells = forAllSystems ({ pkgs, lgxPackage }: {
        default = pkgs.mkShell {
          buildInputs = [ lgxPackage ];
          
          shellHook = ''
            echo "Logos Modules build environment"
            echo "lgx binary available: $(which lgx)"
          '';
        };
      });
    };
}
