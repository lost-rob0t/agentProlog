#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: bash examples/scripts/import-and-check-skill.sh [options]
  --importer FILE  Explicit agentprolog-import-skill executable
  --swipl FILE     Explicit pinned-runtime SWI executable
  --source DIR     Markdown skill root, read as data by the importer
  --output FILE   New native skill file; existing paths are refused
  --help          Show help
Validates inert native terms with load_skill_units/2; never consults output.
No provider calls, project trust, tool grants, or model credentials required.
HELP
}

fail() { echo "$1" >&2; exit 2; }
importer= swipl= source_dir= output=
while (($#)); do
  case "$1" in
    --help) usage; exit 0 ;;
    --importer|--swipl|--source|--output)
      (($# >= 2)) && [[ -n "$2" ]] || fail "Missing value: $1"
      case "$1" in
        --importer) [[ -z "$importer" ]] || fail 'Duplicate --importer'; importer=$2 ;;
        --swipl) [[ -z "$swipl" ]] || fail 'Duplicate --swipl'; swipl=$2 ;;
        --source) [[ -z "$source_dir" ]] || fail 'Duplicate --source'; source_dir=$2 ;;
        --output) [[ -z "$output" ]] || fail 'Duplicate --output'; output=$2 ;;
      esac
      shift 2 ;;
    *) fail "Unknown option: $1" ;;
  esac
done
[[ -n "$importer" && -n "$swipl" && -n "$source_dir" && -n "$output" ]] || fail 'All four inputs are required'
[[ "$importer" = /* && -f "$importer" && -x "$importer" ]] || fail 'importer must be an absolute executable file'
[[ "$swipl" = /* && -f "$swipl" && -x "$swipl" ]] || fail 'swipl must be an absolute executable file'
[[ "$source_dir" = /* && -d "$source_dir" ]] || fail 'source must be an absolute directory'
[[ "$output" = /* && -d "$(dirname -- "$output")" ]] || fail 'output must be absolute with an existing parent'
[[ ! -e "$output" && ! -L "$output" ]] || fail 'output already exists'
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
"$importer" "$source_dir" "$output"
"$swipl" -q -s "$script_dir/check-skill.pl" -- "$output"
echo 'Imported and validated native skill data (no authority granted).'
