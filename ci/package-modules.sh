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
# This script verifies that manifests match across variants (ignoring the "main"
# field which differs per platform), then uses the lgx tool to create a fresh
# multi-variant package from the extracted per-platform files.
#
# All metadata is extracted from the single-variant lgx manifests — no submodule
# checkout is required.

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
  declare -A variant_lgx_map=()
  available_variants=()

  for variant in "${ALL_VARIANTS[@]}"; do
    variant_module_dir="$ARTIFACTS_DIR/${variant}/${module}"
    if [[ -d "$variant_module_dir" ]]; then
      lgx_file=$(find "$variant_module_dir" -maxdepth 1 -name '*.lgx' 2>/dev/null | head -n 1)
      if [[ -n "$lgx_file" ]]; then
        variant_lgx_map["$variant"]="$lgx_file"
        available_variants+=("$variant")
      fi
    fi
  done

  if [[ ${#available_variants[@]} -eq 0 ]]; then
    echo "No lgx artifacts found for $module, skipping."
    continue
  fi

  echo "Available variants for $module: ${available_variants[*]}"

  # Collect lgx file paths for verification
  lgx_file_args=()
  for variant in "${available_variants[@]}"; do
    lgx_file_args+=("${variant_lgx_map[$variant]}")
  done

  # --- Verify manifests match across all single-variant lgx files (ignoring "main") ---
  python3 - "${lgx_file_args[@]}" <<'PY'
import tarfile, json, sys

def read_manifest(lgx_path):
    with tarfile.open(lgx_path, 'r:gz') as tar:
        for member in tar.getmembers():
            if member.name == 'manifest.json':
                return json.loads(tar.extractfile(member).read())
    return None

manifests = []
for path in sys.argv[1:]:
    m = read_manifest(path)
    if m is None:
        print(f"ERROR: no manifest.json found in {path}", file=sys.stderr)
        sys.exit(1)
    manifests.append((path, m))

# Compare all manifests ignoring the "main" field (differs per platform, e.g. .dylib vs .so)
def manifest_without_main(m):
    return {k: v for k, v in m.items() if k != "main"}

reference_path, reference = manifests[0]
ref_comparable = manifest_without_main(reference)

for path, m in manifests[1:]:
    comparable = manifest_without_main(m)
    if comparable != ref_comparable:
        print(f"ERROR: manifest mismatch between {reference_path} and {path}", file=sys.stderr)
        print(f"  Reference: {json.dumps(ref_comparable, sort_keys=True)}", file=sys.stderr)
        print(f"  Mismatch:  {json.dumps(comparable, sort_keys=True)}", file=sys.stderr)
        sys.exit(1)

print(f"Manifests verified: all {len(manifests)} variant(s) match (ignoring main field).")
PY

  # --- Extract metadata from the first single-variant lgx manifest ---
  first_lgx="${variant_lgx_map[${available_variants[0]}]}"

  manifest_json=$(python3 - "$first_lgx" <<'PY'
import tarfile, json, sys
with tarfile.open(sys.argv[1], 'r:gz') as tar:
    for member in tar.getmembers():
        if member.name == 'manifest.json':
            print(tar.extractfile(member).read().decode())
            break
PY
)

  package_name=$(echo "$manifest_json" | python3 -c "import json, sys; print(json.load(sys.stdin).get('name', ''))")

  if [[ -z "$package_name" ]]; then
    # Fall back to lgx filename
    package_name=$(basename "$first_lgx" .lgx)
  fi

  lgx_package_path="$output_dir/${package_name}.lgx"

  # --- Create multi-variant lgx package using the lgx tool ---

  rm -f "${package_name}.lgx"
  "$LGX" create "$package_name"
  mv "${package_name}.lgx" "$lgx_package_path"

  # Patch manifest with metadata extracted from the single-variant lgx
  echo "Updating package manifest with metadata..."
  python3 - "$lgx_package_path" "$manifest_json" <<'PY'
import json, sys, tarfile, io

lgx_path = sys.argv[1]
metadata = json.loads(sys.argv[2])

with tarfile.open(lgx_path, 'r:gz') as tar:
    members = []
    for member in tar.getmembers():
        if member.isfile():
            members.append((member, tar.extractfile(member).read()))
        else:
            members.append((member, None))

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

with tarfile.open(lgx_path, 'w:gz', format=tarfile.GNU_FORMAT) as tar:
    for member, data in patched:
        if data is not None:
            tar.addfile(member, io.BytesIO(data))
        else:
            tar.addfile(member)
PY

  # Add each variant by extracting files from its single-variant lgx
  for variant in "${available_variants[@]}"; do
    lgx_file="${variant_lgx_map[$variant]}"

    # Read the per-variant main file from this variant's lgx manifest
    variant_main=$(python3 - "$lgx_file" <<'PY'
import tarfile, json, sys
with tarfile.open(sys.argv[1], 'r:gz') as tar:
    for member in tar.getmembers():
        if member.name == 'manifest.json':
            m = json.loads(tar.extractfile(member).read())
            print(m.get('main', ''))
            break
PY
)

    # Extract variant files from the single-variant lgx into a temp directory
    extract_dir=$(mktemp -d)
    python3 - "$lgx_file" "$variant" "$extract_dir" <<'PY'
import tarfile, sys, os

lgx_path = sys.argv[1]
variant = sys.argv[2]
extract_dir = sys.argv[3]

prefix = f"variants/{variant}/"

with tarfile.open(lgx_path, 'r:gz') as tar:
    for member in tar.getmembers():
        if member.name.startswith(prefix) and member.isfile():
            rel = member.name[len(prefix):]
            target = os.path.join(extract_dir, rel)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with tar.extractfile(member) as src:
                with open(target, 'wb') as dst:
                    dst.write(src.read())
PY

    # Determine main file for lgx add
    if [[ -z "$variant_main" || ! -f "$extract_dir/$variant_main" ]]; then
      echo "ERROR: main file '${variant_main:-<unset>}' not found for variant $variant of $module, skipping variant." >&2
      rm -rf "$extract_dir"
      continue
    fi

    main_path="$variant_main"

    echo "Adding variant $variant to ${package_name}.lgx (main: $main_path)"
    "$LGX" add "$lgx_package_path" \
      --variant "$variant" \
      --files "$extract_dir/." \
      --main "$main_path" \
      -y || {
      echo "Failed to add variant $variant to LGX package for $package_name" >&2
      exit 1
    }

    rm -rf "$extract_dir"
    echo "Successfully added variant $variant to ${package_name}.lgx"
  done

  # Store entry for list.json generation (metadata from the lgx manifest)
  variants_csv=$(IFS=,; echo "${available_variants[*]}")
  module_entries+=("$module::$manifest_json::${package_name}.lgx::${variants_csv}")
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
