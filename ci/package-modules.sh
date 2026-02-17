#!/usr/bin/env bash
set -euo pipefail
set -x

# package-modules.sh — Create multi-variant .lgx packages from pre-built artifacts.
#
# Expected environment:
#   LGX          — path to the lgx binary
#   ARTIFACTS_DIR — path to downloaded artifacts (default: "artifacts")
#
# Expected directory layout under ARTIFACTS_DIR:
#   build-linux-amd64/<module>/lib/...
#   build-linux-arm64/<module>/lib/...
#   build-darwin-arm64/<module>/lib/...
#
# Module metadata is read from <module>/metadata.json in the repo checkout.

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

  # Check which variants have build output for this module
  available_variants=()
  for variant in "${ALL_VARIANTS[@]}"; do
    variant_lib_dir="$ARTIFACTS_DIR/build-${variant}/${module}/lib"
    if [[ -d "$variant_lib_dir" ]] && [[ -n "$(ls -A "$variant_lib_dir" 2>/dev/null)" ]]; then
      available_variants+=("$variant")
    fi
  done

  if [[ ${#available_variants[@]} -eq 0 ]]; then
    echo "No build output found for $module in any variant, skipping."
    continue
  fi

  echo "Available variants for $module: ${available_variants[*]}"

  # Read metadata
  module_metadata_path="$repo_dir/$module/metadata.json"
  module_metadata_json=$(python3 - "$module_metadata_path" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r") as f:
        metadata = json.load(f)
        result = {
            "type": metadata.get("type", ""),
            "name": metadata.get("name", ""),
            "description": metadata.get("description", ""),
            "dependencies": metadata.get("dependencies", []),
            "category": metadata.get("category", ""),
            "author": metadata.get("author", ""),
            "version": metadata.get("version", "0.0.1"),
            "main": metadata.get("main", "")
        }
        print(json.dumps(result))
except (FileNotFoundError, json.JSONDecodeError, KeyError):
    print(json.dumps({
        "type": "",
        "name": "",
        "description": "",
        "dependencies": [],
        "category": "",
        "author": "",
        "version": "0.0.1",
        "main": ""
    }))
PY
)
  module_metadata_json=${module_metadata_json//$'\n'/}

  package_name=$(echo "$module_metadata_json" | python3 -c "import json, sys; print(json.load(sys.stdin).get('name', ''))")

  if [[ -z "$package_name" ]]; then
    echo "No package name found in metadata.json for $module, skipping." >&2
    continue
  fi

  lgx_package_path="$output_dir/${package_name}.lgx"

  # Create a fresh LGX package
  echo "Creating new LGX package: ${package_name}.lgx"
  rm -f "${package_name}.lgx"

  "$LGX" create "$package_name" || {
    echo "Failed to create LGX package for $package_name" >&2
    exit 1
  }

  mv "${package_name}.lgx" "$lgx_package_path"

  # Patch manifest.json inside the LGX package with module metadata
  echo "Updating package manifest with metadata..."
  python3 - "$lgx_package_path" "$module_metadata_json" <<'PY'
import json
import sys
import tarfile
import io

lgx_path = sys.argv[1]
metadata = json.loads(sys.argv[2])

# Read all members from the original archive
with tarfile.open(lgx_path, 'r:gz') as tar:
    members = []
    for member in tar.getmembers():
        if member.isfile():
            members.append((member, tar.extractfile(member).read()))
        else:
            members.append((member, None))

# Patch the manifest content
patched = []
for member, data in members:
    if member.name == 'manifest.json':
        manifest = json.loads(data)
        for key in ('name', 'version', 'description', 'author', 'type', 'category', 'dependencies'):
            if metadata.get(key):
                manifest[key] = metadata[key]
        data = json.dumps(manifest, indent=2).encode()
        member.size = len(data)
    patched.append((member, data))

# Rewrite the archive preserving original member metadata
with tarfile.open(lgx_path, 'w:gz', format=tarfile.GNU_FORMAT) as tar:
    for member, data in patched:
        if data is not None:
            tar.addfile(member, io.BytesIO(data))
        else:
            tar.addfile(member)
PY

  # Get main entry from metadata
  main_entry=$(echo "$module_metadata_json" | python3 -c "import json, sys; print(json.load(sys.stdin).get('main', ''))")

  # Add each available variant
  for variant in "${available_variants[@]}"; do
    variant_lib_dir="$ARTIFACTS_DIR/build-${variant}/${module}/lib"

    if [[ -n "$main_entry" ]]; then
      # Determine extension based on variant platform
      case "$variant" in
        darwin-*) lib_ext=".dylib" ;;
        linux-*)  lib_ext=".so" ;;
      esac
      main_path="${main_entry}${lib_ext}"
    else
      # Fallback: use first file in library directory
      main_file=$(ls "$variant_lib_dir" | head -n 1)
      if [[ -z "$main_file" ]]; then
        echo "No library files found in $variant_lib_dir" >&2
        exit 1
      fi
      main_path="$main_file"
    fi

    echo "Adding variant $variant to ${package_name}.lgx"
    "$LGX" add "$lgx_package_path" \
      --variant "$variant" \
      --files "$variant_lib_dir/." \
      --main "$main_path" \
      -y || {
      echo "Failed to add variant $variant to LGX package for $package_name" >&2
      exit 1
    }

    echo "Successfully added variant $variant to ${package_name}.lgx"
  done

  # Store entry for list.json generation (variants as comma-separated list)
  variants_csv=$(IFS=,; echo "${available_variants[*]}")
  module_entries+=("$module::$module_metadata_json::${package_name}.lgx::${variants_csv}")
done

# Generate list.json
list_json_path="$output_dir/list.json"

python3 - "$list_json_path" "${module_entries[@]}" <<'PY'
import json
import os
import sys

list_path = sys.argv[1]
entries = sys.argv[2:]

result_index = {}

for raw in entries:
    if "::" not in raw:
        continue
    parts = raw.split("::", 3)
    if len(parts) < 3:
        continue

    name, metadata_json, package_filename = parts[0], parts[1], parts[2]
    variants_csv = parts[3] if len(parts) > 3 else ""

    try:
        metadata = json.loads(metadata_json)
    except json.JSONDecodeError:
        metadata = {}

    item = {"name": name}
    item["package"] = package_filename

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
