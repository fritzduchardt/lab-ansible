#!/usr/bin/bash

set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/../log.sh"
source "$SCRIPT_DIR/../utils.sh"

INPUT_FILE=""
MD_FILE=""

usage() {
  cat << EOF
Usage: $0 -f FILE [OPTIONS]

Remove all image links that reference files not existing in the directory from the specified markdown FILE.

OPTIONS:
  -h       Show this help message

EXAMPLES:
  $0 -f /path/to/file.md
  $0 -h
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      -f)
        if [[ -z "$2" ]]; then
          log::error "Option -f requires a FILE argument"
          usage
          exit 1
        fi
        INPUT_FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log::error "Unexpected argument: $1"
        usage
        exit 1
        ;;
    esac
  done
  if [[ -z "$INPUT_FILE" ]]; then
    log::error "FILE with -f is required"
    usage
    exit 1
  fi
}

remove_missing_image_links() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  local temp_file="$file.tmp"
  local removed_any=false line

  while IFS= read -r line; do
    if [[ "$line" =~ ^\!\[.*\]\(([^\)]+)\)$ ]]; then
      local image_file="${BASH_REMATCH[1]}"
      local full_path="$dir/$image_file"
      if [[ -f "$full_path" ]]; then
        echo "$line" >> "$temp_file"
      else
        log::info "Removing missing image link: $image_file from $file"
        removed_any=true
      fi
    else
      echo "$line" >> "$temp_file"
    fi
  done < "$file"

  if [[ "$removed_any" == "true" ]]; then
    lib::exec mv "$temp_file" "$file"
    log::info "Updated $file with missing image links removed"
  else
    lib::exec rm "$temp_file"
    log::info "No missing image links found in $file"
  fi
}

main() {
  parse_args "$@"

  log::info "Processing file: $INPUT_FILE"
  if [[ "$INPUT_FILE" == *.md ]]; then
    MD_FILE="$INPUT_FILE"
  elif [[ "$INPUT_FILE" == *.png || "$INPUT_FILE" == *.jpg ]]; then
    local base
    base=$(basename "$INPUT_FILE" | sed 's/\-.*$//')
    local dir
    dir=$(dirname "$INPUT_FILE")
    MD_FILE="$dir/$base.md"
    if [[ ! -f "$MD_FILE" ]]; then
      log::error "Deduced markdown file does not exist: $MD_FILE"
      exit 1
    fi
  else
    log::error "FILE must have .md, .png, or .jpg extension: $INPUT_FILE"
    exit 1
  fi

  remove_missing_image_links "$MD_FILE"
  log::info "Processing completed"
}

main "$@"
