#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/utils.sh"

usage() {
  echo """Usage: $0 [options]

Options:
  -f, --file FILE       File to import (required)
  -b, --base BASE       Base path to strip from file paths (default: directory of the file)
  -e, --endpoint URL    Weaviate endpoint URL (default: http://localhost:8080)
  -c, --class NAME      Weaviate class name to import into (default: ObsidianFile)
  -h, --help            Show this help

Examples:
  $0 --file ./docs/notes.md --base ./docs --endpoint http://weaviate.local:8080 --class Document
  $0 -f /data/texts/note.md -b /data -e http://127.0.0.1:8080 -c MyTextClass
"""
}

weaviate::import_file() {
  local endpoint="${1}"
  local class="${2}"
  local base="${3}"
  local file="$4"
  local base_abs
  local file_abs
  local base_path
  local rel
  local payload
  local rc

  log::info "Preparing import for file: $file"

  base_abs="$(lib::exec realpath -- "$base")"
  file_abs="$(lib::exec realpath -- "$file")"

  base_path="${base_abs%/}"
  if [[ -n "$base_path" ]] && [[ "$file_abs" == "$base_path"* ]]; then
    rel="${file_abs#$base_path/}"
  else
    log::error "Base path: $base_path does not match file path: $file_abs"
    exit 2
  fi

  payload="$(lib::exec jq -Rs --arg class "$class" --arg path "$rel" '{class: $class, properties: {path: $path, content: .}}' <"$file_abs")"
  log::debug "Payload for $file_abs: $payload"

  if ! lib::exec curl -sS -X POST -H "Content-Type: application/json" -d "$payload" "$endpoint/v1/objects"; then
    rc=$?
    log::error "Failed to POST object for $file_abs (exit $rc)"
    return 1
  fi
}

main() {
  local file
  local base
  local endpoint
  local class

  file="${FILE}"
  endpoint="${ENDPOINT:-http://weaviate.weaviate}"
  class="${CLASS:-ObsidianFile}"
  base="${BASE:-/volumes/syncthing}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)
        file="$2"
        shift 2
        ;;
      -b|--base)
        base="$2"
        shift 2
        ;;
      -e|--endpoint)
        endpoint="$2"
        shift 2
        ;;
      -c|--class)
        class="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        log::error "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done

  if [[ ! "$file" =~ [Pp]rotocol|[Jj]ournal\.md ]]; then
    log::info "Not processing: $file"
    exit 0
  fi

  if [[ -z "$file" ]]; then
    log::error "No file specified"
    usage
    exit 1
  fi

  if [[ ! -f "$file" ]]; then
    log::error "File not found: $file"
    exit 1
  fi

  if [[ -z "$base" ]]; then
    base="$(dirname -- "$file")"
  fi

  weaviate::import_file "$endpoint" "$class" "$base" "$file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
