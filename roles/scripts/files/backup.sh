#!/usr/bin/bash

set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/log.sh"
source "$SCRIPT_DIR/utils.sh"

usage() {
    echo '''
Usage: backup.sh <s3_url> <backup_dir> <aws_key_id> <aws_secret> <restic_password> [pg_backup] [pg_host] [pg_user] [pg_password] [pg_db]

Backup directories and optionally PostgreSQL databases to S3 using restic.

Parameters:
  s3_url          S3 endpoint URL
  backup_dir      Local directory to backup
  aws_key_id      AWS access key ID
  aws_secret      AWS secret access key
  restic_password Password for restic repository
  pg_backup       Enable PostgreSQL backup (true/false, optional)
  pg_host         PostgreSQL host (optional)
  pg_user         PostgreSQL username (optional)
  pg_password     PostgreSQL password (optional)
  pg_db           PostgreSQL database name (optional, defaults to "app")

Examples:
  '"$0"' s3.amazonaws.com /data/immich AKIAIOSFODNN7EXAMPLE wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY mypassword123
  '"$0"' s3.amazonaws.com /data/immich AKIAIOSFODNN7EXAMPLE wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY mypassword123 true localhost postgres pgpass app
'''
}

validate_parameters() {
    if [[ $# -lt 5 ]]; then
        log::error "Missing required parameters"
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

create_postgres_backup() {
    local backup_dir="$1"
    local pg_host="$2"
    local pg_user="$3"
    local pg_password="$4"
    local pg_db="$5"
    local pg_port="5432"

    log::info "Starting PostgreSQL backup"

    if [[ -n "$pg_password" ]]; then
        export PGPASSWORD="$pg_password"
    fi

    local backup_filename="postgres_backup_$(date +%Y%m%d_%H%M%S).sql"
    local backup_path="$backup_dir/$backup_filename"

    lib::exec pg_dump -h "$pg_host" -p "$pg_port" -U "$pg_user" -f "$backup_path" "$pg_db"
    local pg_dump_result=$?

    send_postgres_metrics "$backup_dir" "$pg_dump_result"

    if [[ $pg_dump_result -ne 0 ]]; then
        log::error "PostgreSQL backup failed with exit code $pg_dump_result"
        if [[ -f "$backup_path" ]]; then
            lib::exec rm -f "$backup_path"
        fi
    else
        log::info "PostgreSQL backup completed successfully: $backup_path"
        compress_and_cleanup_postgres_backup "$backup_path" "$backup_dir"
    fi

    unset PGPASSWORD
}

send_postgres_metrics() {
    local backup_dir="$1"
    local result="$2"

    # Send PostgreSQL backup metrics to Prometheus pushgateway
    cat <<EOF | lib::exec curl --data-binary @- pushgateway-prometheus-pushgateway.pushgateway:9091/metrics/job/backup
postgres_backup_success{dir="$backup_dir"} $result
EOF
}

compress_and_cleanup_postgres_backup() {
    local backup_path="$1"
    local backup_dir="$2"

    lib::exec gzip "$backup_path"

    # Keep only the last 3 PostgreSQL backups
    lib::exec find "$backup_dir" -name "postgres_backup_*.sql.gz" -type f | sort -r | tail -n +4 | xargs -r rm -f
}

perform_restic_backup() {
    local url="$1"
    local backup_dir="$2"
    local bucket_name="friclu-immich"

    log::info "Starting restic backup"

    lib::exec /usr/local/bin/restic unlock -r "s3:https://$url/$bucket_name"

    lib::exec /usr/local/bin/restic -r "s3:https://$url/$bucket_name" backup --skip-if-unchanged "$backup_dir"
    local backup_result=$?

    if [[ $backup_result -ne 0 ]]; then
        log::error "Restic backup failed with exit code $backup_result"
    fi

    send_restic_backup_metrics "$backup_dir" "$backup_result"

    perform_restic_housekeeping "$url" "$bucket_name" "$backup_dir"
}

send_restic_backup_metrics() {
    local backup_dir="$1"
    local result="$2"

    # Send restic backup metrics to Prometheus pushgateway
    if cat <<EOF | lib::exec curl --data-binary @- pushgateway-prometheus-pushgateway.pushgateway:9091/metrics/job/backup; then
restic_backup_success{dir="$backup_dir"} $result
EOF
        log::info "Successfully sent restic backup metrics to Prometheus"
    else
        log::error "Failed to send restic backup metrics to Prometheus"
    fi
}

perform_restic_housekeeping() {
    local url="$1"
    local bucket_name="$2"
    local backup_dir="$3"

    log::info "Starting restic housekeeping"

    lib::exec /usr/local/bin/restic -r "s3:https://$url/$bucket_name" forget --keep-daily 7 --keep-monthly 1 --keep-yearly 1 --prune
    local housekeeping_result=$?

    if [[ $housekeeping_result -ne 0 ]]; then
        log::error "Restic housekeeping failed with exit code $housekeeping_result"
    fi

    send_restic_housekeeping_metrics "$backup_dir" "$housekeeping_result"
}

send_restic_housekeeping_metrics() {
    local backup_dir="$1"
    local result="$2"

    # Send restic housekeeping metrics to Prometheus pushgateway
    if cat <<EOF | lib::exec curl --data-binary @- pushgateway-prometheus-pushgateway.pushgateway:9091/metrics/job/backup; then
restic_backup_housekeeping_success{dir="$backup_dir"} $result
EOF
        log::info "Successfully sent restic housekeeping metrics to Prometheus"
    else
        log::error "Failed to send restic housekeeping metrics to Prometheus"
    fi
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            *)
                break
                ;;
        esac
    done

    validate_parameters "$@"

    local url="${1:?provide s3 url}"
    local backup_dir="${2:?provide bucket dir}"
    local key_id="${3:?provide aws access key id}"
    local secret="${4:?provide aws access secret key}"
    local password="${5:?provide restic password}"
    local pg_backup="${6:-}"
    local pg_host="${7:-}"
    local pg_user="${8:-}"
    local pg_password="${9:-}"
    local pg_db="${10:-app}"

    setup_environment_variables "$key_id" "$secret" "$password"

    if [[ "$pg_backup" = "true" ]]; then
        create_postgres_backup "$backup_dir" "$pg_host" "$pg_user" "$pg_password" "$pg_db"
    fi

    perform_restic_backup "$url" "$backup_dir"

    log::info "Backup process completed"
}

main "$@"
