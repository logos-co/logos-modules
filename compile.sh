#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

base_libraries_dir="$script_dir/libraries"
case "$(uname -s)" in
  Darwin) platform_dir="mac" ;;
  Linux) platform_dir="linux" ;;
  *)
    echo "Unsupported platform: $(uname -s)" >&2
    exit 1
    ;;
esac
libraries_dir="$base_libraries_dir/$platform_dir"

if [[ ! -f .gitmodules ]]; then
  echo "No .gitmodules found in $script_dir" >&2
  exit 1
fi

modules=$(git config --file .gitmodules --get-regexp path | awk '{print $2}')

if [[ -z "$modules" ]]; then
  echo "No module paths found in .gitmodules" >&2
  exit 1
fi

rm -rf "$libraries_dir"
mkdir -p "$libraries_dir"

for module in $modules; do
  echo "Building $module..."
  if (cd "$module" && nix build --extra-experimental-features 'nix-command flakes' '.#lib'); then
    echo "Built $module"
    module_lib_dir="$script_dir/$module/result/lib"
    if [[ ! -d "$module_lib_dir" ]]; then
      echo "Expected library output directory not found for $module at $module_lib_dir" >&2
      exit 1
    fi

    # -RLf dereferences nix store symlinks and avoids preserving ownership to prevent permission issues when overwriting
    cp -RLf "$module_lib_dir"/. "$libraries_dir"/
    echo "Copied libraries for $module to $libraries_dir"
  else
    echo "Failed building $module (nix build '.#lib')" >&2
    exit 1
  fi
done

echo "All modules built successfully."
echo "Libraries aggregated under $libraries_dir."
