#!/usr/bin/bash

set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/utils.sh"

usage() {
  echo '''
Usage: restic.sh <action> <s3_url> <aws_key_id> <aws_secret> <restic_password> [options]

Actions:
  snapshots    Show snapshots in the repository
  restore      Restore a path from the repository

Parameters:
  action           Action to perform: snapshots or restore
  backup_dir       Optional local directory path (for filtering snapshots)
  s3_url           S3 endpoint URL
  aws_key_id       AWS access key ID
  aws_secret       AWS secret access key
  restic_password  Password for restic repository

Options for restore:
  output_dir       Optional output directory for restore (defaults to current directory)
'''
}

validate_parameters() {
  local action="$1"
  shift
  if [[ "$action" == "snapshots" ]]; then
    if [[ $# -lt 4 ]]; then
      log::error "Missing required parameters for snapshots"
      usage
      exit 1
    fi
  elif [[ "$action" == "restore" ]]; then
    if [[ $# -lt 5 ]]; then
      log::error "Missing required parameters for restore"
      usage
      exit 1
    fi
  else
    log::error "Invalid action: $action"
    usage
    exit 1
  fi
}

setup_environment_variables() {
  local key_id="$1"
  local secret="$2"
  local password="$3"

  export AWS_ACCESS_KEY_ID="$key_id"
  export AWS_SECRET_ACCESS_KEY="$secret"
  export RESTIC_PASSWORD="$password"
}

show_snapshots() {
  local url="$1"
  local backup_dir="$2"
  local bucket_name="friclu-immich"

  log::info "Preparing restic connection"

  if [[ -z "$backup_dir" ]]; then
    if ! lib::exec /usr/local/bin/restic snapshots -r \
      "s3:https://$url/$bucket_name"; then
      log::error "Failed to read restic repository"
      exit 1
    fi
  else
    if ! lib::exec /usr/local/bin/restic snapshots -r \
      "s3:https://$url/$bucket_name" --path "$backup_dir"; then
      log::error "Failed to read restic repository"
      exit 1
    fi
  fi
}

restore_path() {
  local url="$1"
  local backup_dir="$2"
  local output_dir="${3:-.}"
  local bucket_name="friclu-immich"

  log::info "Preparing restic connection for restore"

  if ! lib::exec /usr/local/bin/restic restore latest -r \
    "s3:https://$url/$bucket_name" --target "$output_dir" --path \
    "$backup_dir"; then
    log::error "Failed to restore path from restic repository"
    exit 1
  fi
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      *)
        break
        ;;
    esac
  done

  local action="${1:?provide action}"
  shift

  validate_parameters "$action" "$@"

  local url="${1:?provide s3 url}"
  local backup_dir="$2"
  local key_id="${3:?provide aws access key id}"
  local secret="${4:?provide aws access secret key}"
  local password="${5:?provide restic password}"

  setup_environment_variables "$key_id" "$secret" "$password"

  if [[ "$action" == "snapshots" ]]; then
    show_snapshots "$url" "$backup_dir"
    log::info "Snapshots displayed"
  elif [[ "$action" == "restore" ]]; then
    local output_dir="$6"
    restore_path "$url" "$backup_dir" "$output_dir"
    log::info "Path restored to $output_dir"
  fi

  log::info "Operation completed"
}

main "$@"
