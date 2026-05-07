#!/usr/bin/env bash
set -euo pipefail
set -x

# package-modules.sh — Merge single-variant .lgx packages into multi-variant ones.
#
# Expected environment:
#   LGX           — path to the lgx binary
#   ARTIFACTS_DIR — path to downloaded artifacts (default: "artifacts")
#
# Expected directory layout under ARTIFACTS_DIR:
#   <variant>/<module>/<package>.lgx
#
# Each input .lgx is a single-variant package produced by nix-bundle-lgx.
# This script uses `lgx merge` to combine single-variant packages into
# multi-variant packages.

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$script_dir/.." && pwd)"

: "${LGX:?LGX env var must point to the lgx binary}"
: "${ARTIFACTS_DIR:=artifacts}"

output_dir="$repo_dir/output"
mkdir -p "$output_dir"

ALL_VARIANTS=("linux-amd64" "linux-arm64" "darwin-arm64")

if [[ ! -f "$repo_dir/.gitmodules" ]]; then
  echo "No .gitmodules found in $repo_dir" >&2
  exit 1
fi

modules=$(git config --file "$repo_dir/.gitmodules" --get-regexp path | awk '{print $2}')

if [[ -z "$modules" ]]; then
  echo "No module paths found in .gitmodules" >&2
  exit 1
fi

# Store module metadata for list.json generation
module_entries=()

for module in $modules; do
  echo "=== Processing $module ==="

  # Collect all single-variant lgx files for this module
  lgx_files=()
  available_variants=()

  for variant in "${ALL_VARIANTS[@]}"; do
    variant_module_dir="$ARTIFACTS_DIR/${variant}/${module}"
    if [[ -d "$variant_module_dir" ]]; then
      lgx_file=$(find "$variant_module_dir" -maxdepth 1 -name '*.lgx' 2>/dev/null | head -n 1)
      if [[ -n "$lgx_file" ]]; then
        lgx_files+=("$lgx_file")
        available_variants+=("$variant")
      fi
    fi
  done

  if [[ ${#lgx_files[@]} -eq 0 ]]; then
    echo "No lgx artifacts found for $module, skipping."
    continue
  fi

  echo "Available variants for $module: ${available_variants[*]}"

  # Extract package name from the first lgx file's manifest
  first_lgx="${lgx_files[0]}"
  package_name=$(python3 - "$first_lgx" <<'PY'
import tarfile, json, sys
with tarfile.open(sys.argv[1], 'r:gz') as tar:
    for member in tar.getmembers():
        if member.name == 'manifest.json':
            m = json.loads(tar.extractfile(member).read())
            print(m.get('name', ''))
            break
PY
)

  if [[ -z "$package_name" ]]; then
    package_name=$(basename "$first_lgx" .lgx)
  fi

  lgx_package_path="$output_dir/${package_name}.lgx"

  # Merge all single-variant lgx files into one multi-variant package
  "$LGX" merge "${lgx_files[@]}" -o "$lgx_package_path" -y

  echo "Created multi-variant package: ${package_name}.lgx"

  # Extract manifest metadata from the merged package for list.json generation
  manifest_json=$(python3 - "$lgx_package_path" <<'PY'
import tarfile, json, sys
with tarfile.open(sys.argv[1], 'r:gz') as tar:
    for member in tar.getmembers():
        if member.name == 'manifest.json':
            print(tar.extractfile(member).read().decode())
            break
PY
)

  variants_csv=$(IFS=,; echo "${available_variants[*]}")

  package_size=$(python3 -c 'import os,sys; print(os.path.getsize(sys.argv[1]))' "$lgx_package_path")

  # Date of the commit the submodule pointer references — i.e. when the
  # code the user actually downloads was authored.
  if [[ ! -e "$repo_dir/$module/.git" ]]; then
    echo "Error: submodule $module is not checked out (no .git under $repo_dir/$module)." >&2
    echo "       Run 'git submodule update --init --recursive' or set 'submodules: true'" >&2
    echo "       on the actions/checkout step." >&2
    exit 1
  fi
  package_date=$(TZ=UTC git -C "$repo_dir/$module" log -1 \
    --date=format:'%Y-%m-%dT%H:%M:%SZ' --format=%cd)

  module_entries+=("$module::$manifest_json::${package_name}.lgx::${variants_csv}::${package_size}::${package_date}")
done

# Generate list.json
list_json_path="$output_dir/list.json"

python3 - "$list_json_path" "${module_entries[@]}" <<'PY'
import json, os, sys

list_path = sys.argv[1]
entries = sys.argv[2:]

result_index = {}

for raw in entries:
    if "::" not in raw:
        continue
    parts = raw.split("::", 5)
    if len(parts) < 3:
        continue

    name, metadata_json, package_filename = parts[0], parts[1], parts[2]
    variants_csv = parts[3] if len(parts) > 3 else ""
    size_str     = parts[4] if len(parts) > 4 else ""
    date_str     = parts[5] if len(parts) > 5 else ""

    try:
        metadata = json.loads(metadata_json)
    except json.JSONDecodeError:
        metadata = {}

    item = {"name": name}
    item["package"] = package_filename
    item["manifest"] = metadata

    if "type" in metadata:
        item["type"] = metadata["type"]
    if "name" in metadata:
        item["moduleName"] = metadata["name"]
    if "description" in metadata:
        item["description"] = metadata["description"]
    if "dependencies" in metadata:
        item["dependencies"] = metadata["dependencies"]
    if "category" in metadata:
        item["category"] = metadata["category"]
    if "author" in metadata:
        item["author"] = metadata["author"]
    if metadata.get("version"):
        item["version"] = metadata["version"]
    if variants_csv:
        item["variants"] = [v for v in variants_csv.split(",") if v]
    if size_str:
        try:
            item["size"] = int(size_str)
        except ValueError:
            pass
    if date_str:
        item["dateUpdated"] = date_str

    result_index[name] = item

result = [result_index[k] for k in sorted(result_index)]
os.makedirs(os.path.dirname(list_path), exist_ok=True)
with open(list_path, "w") as f:
    json.dump(result, f, indent=2)
PY

echo ""
echo "All modules packaged successfully."
echo "LGX packages created in $output_dir"
echo "Package list written to $list_json_path"
