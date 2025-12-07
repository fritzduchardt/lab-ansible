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

Iterate recursively over markdown files in FOLDER and remove image links whose image files are not present in the same folder.

OPTIONS:
  -f FILE        Process only the specified markdown FILE
  --all-images   Ignored (accepted for compatibility with process_md_images.sh)
  -h             Show this help message

EXAMPLES:
  $0 /path/to/folder
  $0 -f /path/to/file.md
  $0 --all-images /path/to/folder
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
      --all-images)
        shift
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

remove_broken_links_from_file() {
  local file="$1"
  local dir
  dir=$(dirname "$file")
  local temp_file="$file.tmp"
  local changed=0

  : > "$temp_file"

  # This loop scans each line of the markdown file; image links are matched and the referenced
  # file is checked in the same directory. If it does not exist, the entire image link is removed.
  while IFS= read -r line; do
    local newline="$line"
    while [[ "$newline" =~ \!\[[^]]*\]\(([^)]+)\) ]]; do
      local full_match="${BASH_REMATCH[0]}"
      local path="${BASH_REMATCH[1]}"
      local img_file
      img_file=$(basename "$path")
      if [[ ! -f "$dir/$img_file" ]]; then
        log::debug "Removing broken image link $img_file from $file"
        newline="${newline//$full_match/}"
        changed=1
      else
        local prefix="${newline%%"$full_match"*}"
        local suffix="${newline#*"$full_match"}"
        newline="$prefix$full_match$suffix"
        local before
        before="${newline%%"$full_match"*}"
        local after
        after="${newline#*"$full_match"}"
        if [[ "$before" == "$newline" || "$after" == "$newline" ]]; then
          break
        fi
      fi
      if [[ "$newline" != *"!["*"]("*")"* ]]; then
        break
      fi
    done
    if [[ "$newline" =~ ^[[:space:]]*$ ]]; then
      echo "" >> "$temp_file"
    else
      echo "$newline" >> "$temp_file"
    fi
  done < "$file"

  if [[ $changed -eq 1 ]]; then
    log::info "Updating file without broken image links: $file"
    lib::exec mv "$temp_file" "$file"
  else
    lib::exec rm "$temp_file"
  fi
}

main() {
  parse_args "$@"
  if [[ -n "$FILE" ]]; then
    log::info "Processing single markdown file for broken image links: $FILE"
    remove_broken_links_from_file "$FILE"
    log::info "Processing completed"
  else
    log::info "Starting processing of markdown files in $FOLDER for broken image links"
    while IFS= read -r file; do
      remove_broken_links_from_file "$file"
    done < <(lib::exec find "$FOLDER" -name "*.md" -type f)
    log::info "Processing completed"
  fi
}

main "$@"
