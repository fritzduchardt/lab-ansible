#!/usr/bin/bash

set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/../log.sh"
source "$SCRIPT_DIR/../utils.sh"

INPUT_FILE=""
MD_FILE=""

usage() {
  cat << EOF
Usage: $0 -f FILE

Process the specified markdown FILE or image FILE (PNG/JPG), deducing the markdown file from the image file name if an image is provided. Add image links after the first text paragraph for all matching image files (PNG or JPG) that start with the same base name as the markdown file, sorted in chronological order (by modification time, oldest first), if they are not already present.

OPTIONS:
  -f FILE  Process the specified markdown FILE or image FILE
  -h       Show this help message

EXAMPLES:
  $0 -f /path/to/file.md
  $0 -f /path/to/file.png
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
  if [[ ! -f "$INPUT_FILE" ]]; then
    log::error "Input FILE does not exist or is not a file: $INPUT_FILE"
    exit 1
  fi
  if [[ "$INPUT_FILE" == *.md ]]; then
    MD_FILE="$INPUT_FILE"
  elif [[ "$INPUT_FILE" == *.png || "$INPUT_FILE" == *.jpg ]]; then
    local base
    base=$(basename "$INPUT_FILE" | sed 's/\_.*$//')
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
}

process_file() {
  local file="$1"
  local base
  base=$(basename "$file" .md)
  base="${base// /g}"
  local dir
  dir=$(dirname "$file")
  local images=()
  while IFS= read -r img; do
    images+=("$img")
  done < <(ls -1 "$dir/$base"*.png "$dir/$base"*.jpg | sort -V)
  if [[ ${#images[@]} -eq 0 ]]; then
    log::info "No matching images found for $file"
    return
  fi
  local to_add=()
  for img in "${images[@]}"; do
    local img_name
    img_name=$(basename "$img")
    if ! grep -q "$img_name" "$file"; then
      to_add+=("$img_name")
    fi
  done
  if [[ ${#to_add[@]} -eq 0 ]]; then
    log::info "All matching images already present in $file"
    return
  fi
  log::info "Adding image links to $file"
  local inserted=0
  local temp_file="$file.tmp"
  local found_headline=0
  local found_paragraph=0
  while IFS= read -r line; do
    if [[ $inserted -eq 0 && $found_headline -eq 1 && $found_paragraph -eq 1 && "$line" == "" ]]; then
      echo "" >> "$temp_file"
      for img in "${to_add[@]}"; do
        echo -e "![]($img)\n" >> "$temp_file"
      done
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
    echo "" >> "$temp_file"
    for img in "${to_add[@]}"; do
      echo -e "![]($img)\n" >> "$temp_file"
    done
  fi
  lib::exec mv "$temp_file" "$file"
}

main() {
  parse_args "$@"
  log::info "Processing file: $MD_FILE"
  process_file "$MD_FILE"
  log::info "Processing completed"
}

main "$@"
