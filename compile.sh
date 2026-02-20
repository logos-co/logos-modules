#!/usr/bin/env bash
set -euo pipefail
set -x

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

base_libraries_dir="$script_dir/libraries"
list_json_path="$base_libraries_dir/list.json"

BUNDLER="${BUNDLER:-github:logos-co/nix-bundle-lgx#portable}"

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

# Store module metadata for list.json generation
module_entries=()

for module in $modules; do
  echo "Building $module..."
  if (cd "$module" && nix bundle --extra-experimental-features 'nix-command flakes' --bundler "$BUNDLER" -o result .#lib); then
    echo "Built $module"

    lgx_file=$(find "$script_dir/$module/result" -maxdepth 1 -name '*.lgx' 2>/dev/null | head -n 1)
    if [[ -z "$lgx_file" ]]; then
      echo "No lgx file found in $module/result/" >&2
      exit 1
    fi

    package_name=$(basename "$lgx_file" .lgx)
    cp "$lgx_file" "$base_libraries_dir/"

    echo "Created ${package_name}.lgx"

    # Read metadata for list.json
    module_metadata_path="$script_dir/$module/metadata.json"
    module_metadata_json=$(python3 - "$module_metadata_path" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        print(json.dumps(json.load(f)))
except:
    print("{}")
PY
)

    module_entries+=("$module::$module_metadata_json::${package_name}.lgx")
  else
    echo "Failed building $module" >&2
    exit 1
  fi
done

# Generate list.json
python3 - "$list_json_path" "${module_entries[@]}" <<'PY'
import json, os, sys

list_path = sys.argv[1]
entries = sys.argv[2:]

result_index = {}

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

    item = {"name": name, "package": package_filename}
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

    result_index[name] = item

result = [result_index[k] for k in sorted(result_index)]
os.makedirs(os.path.dirname(list_path), exist_ok=True)
with open(list_path, "w") as f:
    json.dump(result, f, indent=2)
PY

echo "All modules built successfully."
echo "LGX packages created in $base_libraries_dir"
echo "Package list written to $list_json_path."
