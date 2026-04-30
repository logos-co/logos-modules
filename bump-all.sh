#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$script_dir"

if [[ ! -f .gitmodules ]]; then
  echo "No .gitmodules found in $script_dir" >&2
  exit 1
fi

echo "Initializing submodules..."
git submodule update --init --recursive

modules=()
while IFS= read -r module_path; do
  modules+=("$module_path")
done < <(git config --file .gitmodules --get-regexp path | awk '{print $2}')

if [[ ${#modules[@]} -eq 0 ]]; then
  echo "No submodule paths found in .gitmodules" >&2
  exit 1
fi

updated=0
unchanged=0
skipped=0
failed=0

echo "Bumping submodules to latest main/master..."

for module in "${modules[@]}"; do
  echo
  echo "==> $module"

  if [[ ! -d "$module/.git" && ! -f "$module/.git" ]]; then
    echo "  ! not initialized, skipping"
    ((skipped+=1))
    continue
  fi

  if [[ -n "$(git -C "$module" status --porcelain)" ]]; then
    echo "  ! dirty working tree, skipping"
    ((skipped+=1))
    continue
  fi

  target_branch=""
  if git -C "$module" ls-remote --exit-code --heads origin main >/dev/null 2>&1; then
    target_branch="main"
  elif git -C "$module" ls-remote --exit-code --heads origin master >/dev/null 2>&1; then
    target_branch="master"
  fi

  if [[ -z "$target_branch" ]]; then
    echo "  ! neither origin/main nor origin/master exists, skipping"
    ((skipped+=1))
    continue
  fi

  if ! git -C "$module" fetch --quiet origin "$target_branch"; then
    echo "  ! fetch failed for origin/$target_branch"
    ((failed+=1))
    continue
  fi

  old_sha="$(git -C "$module" rev-parse HEAD)"
  new_sha="$(git -C "$module" rev-parse "origin/$target_branch")"

  if [[ "$old_sha" == "$new_sha" ]]; then
    echo "  = already up to date on origin/$target_branch (${old_sha:0:12})"
    ((unchanged+=1))
    continue
  fi

  if git -C "$module" checkout --quiet --detach "$new_sha"; then
    echo "  + updated to origin/$target_branch ${old_sha:0:12} -> ${new_sha:0:12}"
    ((updated+=1))
  else
    echo "  ! checkout failed"
    ((failed+=1))
  fi
done

echo
echo "Summary: updated=$updated unchanged=$unchanged skipped=$skipped failed=$failed"
echo "Run: git status"
