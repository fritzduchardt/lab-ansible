#!/usr/bin/bash

set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/../log.sh"
source "$SCRIPT_DIR/../utils.sh"

FOLDER=""
FILE=""

usage() {
  cat << EOF
Usage: $0 [OPTIONS] [FOLDER]

Iterate recursively over markdown files in FOLDER and remove all image links that reference files not existing in the directory.

OPTIONS:
  -f FILE  Process only the specified markdown FILE
  -h       Show this help message

EXAMPLES:
  $0 /path/to/folder
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
        FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        if [[ -z "$FOLDER" ]]; then
          FOLDER="$1"
        else
          log::error "Unexpected argument: $1"
          usage
          exit 1
        fi
        shift
        ;;
    esac
  done
  if [[ -n "$FILE" ]]; then
    if [[ ! -f "$FILE" ]]; then
      log::error "FILE does not exist or is not a file: $FILE"
      exit 1
    fi
    if [[ "$FILE" != *.md ]]; then
      log::error "FILE must have .md extension: $FILE"
      exit 1
    fi
  elif [[ -n "$FOLDER" ]]; then
    if [[ ! -d "$FOLDER" ]]; then
      log::error "FOLDER does not exist or is not a directory: $FOLDER"
      exit 1
    fi
  else
    log::error "Either FILE with -f or FOLDER is required"
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

  if [[ -n "$FILE" ]]; then
    log::info "Processing single file: $FILE"
    remove_missing_image_links "$FILE"
    log::info "Processing completed"
  else
    log::info "Starting processing of markdown files in $FOLDER"
    while IFS= read -r file; do
      remove_missing_image_links "$file"
    done < <(lib::exec find "$FOLDER" -name "*.md" -type f)
    log::info "Processing completed"
  fi
}

main "$@"
