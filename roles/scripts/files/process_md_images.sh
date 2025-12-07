#!/usr/bin/bash

set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/utils.sh"

FOLDER=""
FILE=""

usage() {
  cat << EOF
Usage: $0 [OPTIONS] [FOLDER]

Iterate recursively over markdown files in FOLDER and for each file that has a matching PNG file in the same folder, add an image link after the first text paragraph if not already present.

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

process_file() {
  local file="$1"
  local base
  base=$(basename "$file" .md)
  local dir
  dir=$(dirname "$file")
  local png_file="$dir/$base.png"
  if [[ -f "$png_file" ]]; then
    if ! grep -q "$base.png" "$file"; then
      log::info "Adding image link to $file"
      local inserted=0
      local temp_file="$file.tmp"
      local found_headline=0
      local found_paragraph=0
      while IFS= read -r line; do
        if [[ $inserted -eq 0 && $found_headline -eq 1 && $found_paragraph -eq 1 && "$line" == "" ]]; then
          echo """
![]($base.png)""" >> "$temp_file"
          inserted=1
        fi
        if [[ $found_headline -eq 0 && "$line" =~ ^# ]]; then
          found_headline=1
        elif [[ $found_headline -eq 1 && "$line" != "" ]]; then
          found_paragraph=1
        fi
        echo "$line" >> "$temp_file"
      done < "$file"
      if [[ $inserted -eq 0 ]]; then
          echo """
![]($base.png)""" >> "$temp_file"
      fi
      lib::exec mv "$temp_file" "$file"
    else
      log::info "Image link already present in $file"
    fi
  fi
}

main() {
  parse_args "$@"
  if [[ -n "$FILE" ]]; then
    log::info "Processing single file: $FILE"
    process_file "$FILE"
    log::info "Processing completed"
  else
    log::info "Starting processing of markdown files in $FOLDER"
    while IFS= read -r file; do
      process_file "$file"
    done < <(lib::exec find "$FOLDER" -name "*.md" -type f)
    log::info "Processing completed"
  fi
}

main "$@"
