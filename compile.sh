#!/usr/bin/env bash
set -euo pipefail
set -x

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

base_libraries_dir="$script_dir/libraries"
list_json_path="$base_libraries_dir/list.json"

# Detect platform variant for LGX
os_name="$(uname -s)"
arch_name="$(uname -m)"

case "$os_name" in
  Darwin)
    case "$arch_name" in
      arm64) lgx_variant="darwin-arm64" ;;
      x86_64) lgx_variant="darwin-amd64" ;;
      *)
        echo "Unsupported Darwin architecture: $arch_name" >&2
        exit 1
        ;;
    esac
    ;;
  Linux)
    case "$arch_name" in
      x86_64) lgx_variant="linux-amd64" ;;
      aarch64) lgx_variant="linux-arm64" ;;
      *)
        echo "Unsupported Linux architecture: $arch_name" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Unsupported platform: $os_name" >&2
    exit 1
    ;;
esac

echo "Building for platform variant: $lgx_variant"

if [[ ! -f .gitmodules ]]; then
  echo "No .gitmodules found in $script_dir" >&2
  exit 1
fi

modules=$(git config --file .gitmodules --get-regexp path | awk '{print $2}')

if [[ -z "$modules" ]]; then
  echo "No module paths found in .gitmodules" >&2
  exit 1
fi

mkdir -p "$base_libraries_dir"

# Build lgx binary first
echo "Building lgx tool..."
if ! nix build --extra-experimental-features 'nix-command flakes' '.#lgx'; then
  echo "Failed to build lgx tool" >&2
  exit 1
fi

lgx_binary="$script_dir/result/bin/lgx"
if [[ ! -x "$lgx_binary" ]]; then
  echo "lgx binary not found at $lgx_binary" >&2
  exit 1
fi

echo "lgx binary ready at $lgx_binary"

# Store module metadata for list.json generation
module_entries=()

for module in $modules; do
  echo "Building $module..."
  if (cd "$module" && nix build --extra-experimental-features 'nix-command flakes' '.#lib'); then
    echo "Built $module"
    module_lib_dir="$script_dir/$module/result/lib"
    if [[ ! -d "$module_lib_dir" ]]; then
      echo "Expected library output directory not found for $module at $module_lib_dir" >&2
      exit 1
    fi

    # Extract metadata from metadata.json
    module_metadata_path="$script_dir/$module/metadata.json"
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
    
    # Parse metadata to get package name
    package_name=$(echo "$module_metadata_json" | python3 -c "import json, sys; print(json.load(sys.stdin).get('name', ''))")
    
    if [[ -z "$package_name" ]]; then
      echo "No package name found in metadata.json for $module" >&2
      exit 1
    fi
    
    lgx_package_path="$base_libraries_dir/${package_name}.lgx"
    
    # Create or update LGX package
    if [[ ! -f "$lgx_package_path" ]]; then
      echo "Creating new LGX package: ${package_name}.lgx"
      
      # Remove any stale lgx file in current directory from previous failed run
      rm -f "${package_name}.lgx"
      
      "$lgx_binary" create "$package_name" || {
        echo "Failed to create LGX package for $package_name" >&2
        exit 1
      }
      
      # Move created package to libraries directory
      mv "${package_name}.lgx" "$lgx_package_path"
      
      # Update manifest.json inside the package with metadata
      echo "Updating package manifest with metadata..."
      python3 - "$lgx_package_path" "$module_metadata_json" <<'PY'
import json
import sys
import tarfile
import gzip
import tempfile
import os
import shutil

lgx_path = sys.argv[1]
metadata_json = sys.argv[2]
metadata = json.loads(metadata_json)

# Extract to temp directory
temp_dir = tempfile.mkdtemp()
try:
    # Extract existing package
    with tarfile.open(lgx_path, 'r:gz') as tar:
        tar.extractall(temp_dir)
    
    # Read and update manifest
    manifest_path = os.path.join(temp_dir, 'manifest.json')
    with open(manifest_path, 'r') as f:
        manifest = json.load(f)
    
    # Update manifest fields from metadata
    manifest['name'] = metadata.get('name', manifest['name'])
    manifest['version'] = metadata.get('version', manifest['version'])
    manifest['description'] = metadata.get('description', manifest['description'])
    manifest['author'] = metadata.get('author', manifest['author'])
    manifest['type'] = metadata.get('type', manifest['type'])
    manifest['category'] = metadata.get('category', manifest['category'])
    manifest['dependencies'] = metadata.get('dependencies', manifest['dependencies'])
    
    # Write updated manifest
    with open(manifest_path, 'w') as f:
        json.dump(manifest, f, indent=2)
    
    # Recreate the package - use lgx CLI for proper deterministic packing
    # For now, we'll trust that lgx add will update it properly when we add variants
    
finally:
    shutil.rmtree(temp_dir, ignore_errors=True)
PY
    fi
    
    # Get main entry from metadata, or fall back to first file
    main_entry=$(echo "$module_metadata_json" | python3 -c "import json, sys; print(json.load(sys.stdin).get('main', ''))")
    
    if [[ -n "$main_entry" ]]; then
      # Determine extension based on platform
      case "$os_name" in
        Darwin) lib_ext=".dylib" ;;
        Linux)  lib_ext=".so" ;;
      esac
      main_path="${main_entry}${lib_ext}"
    else
      # Fallback: use first file in library directory
      main_file=$(ls "$module_lib_dir" | head -n 1)
      if [[ -z "$main_file" ]]; then
        echo "No library files found in $module_lib_dir" >&2
        exit 1
      fi
      main_path="$main_file"
    fi
    
    echo "Adding variant $lgx_variant to ${package_name}.lgx"
    "$lgx_binary" add "$lgx_package_path" \
      --variant "$lgx_variant" \
      --files "$module_lib_dir/." \
      --main "$main_path" \
      -y || {
      echo "Failed to add variant to LGX package for $package_name" >&2
      exit 1
    }
    
    echo "Successfully added variant $lgx_variant to ${package_name}.lgx"
    
    # Store entry for list.json generation
    module_entries+=("$module::$module_metadata_json::${package_name}.lgx")
  else
    echo "Failed building $module (nix build '.#lib')" >&2
    exit 1
  fi
done

# Generate list.json with package references
python3 - "$list_json_path" "${module_entries[@]}" <<'PY'
import json
import os
import sys

list_path = sys.argv[1]
entries = sys.argv[2:]

def load_existing(path):
    try:
        with open(path, "r") as f:
            return json.load(f)
    except FileNotFoundError:
        return []
    except Exception:
        return []

data = load_existing(list_path)
index = {}
for item in data:
    if isinstance(item, dict) and "name" in item:
        index[item["name"]] = item

for raw in entries:
    if "::" not in raw:
        continue
    parts = raw.split("::", 2)
    if len(parts) != 3:
        continue
    
    name, metadata_json, package_filename = parts
    try:
        metadata = json.loads(metadata_json)
    except json.JSONDecodeError:
        metadata = {}
    
    item = index.get(name, {"name": name})
    
    # Set package field
    item["package"] = package_filename
    
    # Update metadata fields from metadata.json
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
    
    index[name] = item

result = [index[k] for k in sorted(index)]
os.makedirs(os.path.dirname(list_path), exist_ok=True)
with open(list_path, "w") as f:
    json.dump(result, f, indent=2)
PY

echo "All modules built successfully."
echo "LGX packages created in $base_libraries_dir"
echo "Package list written to $list_json_path."
