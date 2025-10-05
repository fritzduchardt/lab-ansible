#!/usr/bin/env bash
set -eo pipefail
SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/utils.sh"

usage() {
  local me="$0"
  cat <<EOF
Usage: $me [OPTIONS]

This script configures iptables rules and kernel settings to route TCP traffic
on ports 80 and 443 to a target IP via a Tailscale interface. It runs all
commands on a remote SSH host.

Options:
  -s, --ssh-host <user@host> SSH target to run commands on (or set SSH_HOST)
  -i, --iface <iface>       Interface name to use on remote host (overrides TAILSCALE_IF)
  -l, --local-ip <ip>       Remote host's local wireguard IPv4 to use as SNAT source (or set TAILSCALE_LOCAL_IP)
  -t, --target <ip>         Target IP to DNAT traffic to (overrides TAILSCALE_TARGET_IP)
  -r, --remove              Remove rules instead of adding them
  -h, --help                Show this help

Environment variables:
  SSH_HOST               SSH target to run commands on (required unless -s provided)
  TAILSCALE_IF           Interface name to use on remote host (default: wireguard0)
  TAILSCALE_TARGET_IP    Target IP to DNAT traffic to (default: same as TAILSCALE_LOCAL_IP)
  TAILSCALE_LOCAL_IP     Remote host's local wireguard IPv4 to use as SNAT source (required unless -l provided)

Examples:
  # Apply routing using the default interface and provided local wireguard IP (remote host must be provided)
  "$me" -s user@remote.example.com -l 100.64.0.5

  # Apply routing for a specific target IP and interface on the remote host using an explicit local wireguard IP
  "$me" -s user@remote.example.com -i ts0 -l 100.64.0.5 -t 100.64.0.10

  # Remove the rules on the remote host
  "$me" -s user@remote.example.com -l 100.64.0.5 -r

EOF
}

# Run a command on the configured SSH host. This prefixes the local invocation with lib::exec
# so the ssh invocation itself is logged/handled consistently. The remote command and its
# arguments are passed as-is (no additional local shell evaluation of the remote command).
run_cmd() {
  local -a cmd=()
  cmd=("$@")
  lib::exec ssh "$ssh_host" -- "${cmd[@]}"
}

# Conceptual: Enable IP forwarding at the kernel level on the remote host so the host can route packets
# between interfaces (necessary when we DNAT/SNAT traffic to/from the wireguard interface).
apply_sysctl() {
  local conf_file="/etc/sysctl.d/99-wireguard-routing.conf"
  local content="net.ipv4.ip_forward=1"

  log::debug "Writing sysctl config to $conf_file on remote host $ssh_host"

  # Write the configuration file on the remote host by piping the content into remote tee.
  printf "%s\n" "$content" | run_cmd tee "$conf_file" >/dev/null

  # apply sysctl settings system-wide on the remote host
  if ! run_cmd sysctl --system >/dev/null 2>&1; then
    log::error "sysctl --system failed applying $conf_file on remote host $ssh_host"
    return 1
  fi

  log::debug "Applied sysctl config to enable ip forwarding on remote host $ssh_host"
}

# Conceptual: Remove existing NAT, FORWARD, and INPUT rules on the remote host that target the wireguard interface
# and the configured target IP. This ensures idempotency when removing rules.
# The rules managed here are specific to TCP ports 80 and 443.
flush_rules() {
  local wireguard_if="$1"
  local target_ip="$2"
  local local_ts_ip="$3"

  log::debug "Flushing existing iptables rules for target $target_ip via $wireguard_if (ports 80,443) on $ssh_host"

  # iptables: delete DNAT PREROUTING rule matching TCP dport 80,443 coming from non-wireguard interfaces
  # Command details:
  #   -t nat : operate on the NAT table
  #   -D PREROUTING : delete a rule from the PREROUTING chain
  #   -p tcp : match TCP protocol
  #   -m multiport --dports 80,443 : match destination ports 80 and 443
  #   "!" -i "$wireguard_if" : match packets incoming on any interface that is NOT wireguard_if
  #   -j DNAT --to-destination "$target_ip" : jump to DNAT target and set destination address to target_ip
  run_cmd iptables -t nat -D PREROUTING -p tcp -m multiport --dports 80,443 "!" -i "$wireguard_if" -j DNAT --to-destination "$target_ip" 2>/dev/null || true

  # iptables: delete SNAT POSTROUTING rule to set source to local wireguard ip for outgoing wireguard packets
  # Command details:
  #   -t nat -D POSTROUTING : delete a rule from the POSTROUTING chain in the nat table
  #   -o "$wireguard_if" : match packets going out via wireguard_if
  #   -j SNAT --to-source "$local_ts_ip" : rewrite source to local_ts_ip
  run_cmd iptables -t nat -D POSTROUTING -o "$wireguard_if" -j SNAT --to-source "$local_ts_ip" 2>/dev/null || true

  # iptables: delete FORWARD rule allowing packets from non-wireguard to wireguard for matched ports
  # Command details:
  #   -D FORWARD : delete a rule from FORWARD chain
  #   "!" -i "$wireguard_if" -o "$wireguard_if" : match packets in on non-wireguard and out on wireguard
  #   -p tcp -m multiport --dports 80,443 : match tcp dst ports 80 and 443
  #   -m conntrack --ctstate NEW,ESTABLISHED,RELATED : match connection states NEW, ESTABLISHED, RELATED
  #   -j ACCEPT : accept matched packets
  run_cmd iptables -D FORWARD "!" -i "$wireguard_if" -o "$wireguard_if" -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

  # iptables: delete FORWARD rule allowing established/related returning traffic from wireguard to non-wireguard
  # Command details:
  #   -D FORWARD : delete a rule from FORWARD chain
  #   -i "$wireguard_if" "!" -o "$wireguard_if" : match packets in on wireguard and out on non-wireguard
  #   -m conntrack --ctstate ESTABLISHED,RELATED : only allow established or related connections back
  #   -j ACCEPT : accept matched packets
  run_cmd iptables -D FORWARD -i "$wireguard_if" "!" -o "$wireguard_if" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true

  # iptables: delete INPUT rule allowing incoming TCP ports 80 and 443 to the VM
  # Command details:
  #   -D INPUT : delete a rule from INPUT chain
  #   -p tcp : match TCP protocol
  #   -m multiport --dports 80,443 : match destination ports 80 and 443
  #   -j ACCEPT : accept matched packets
  run_cmd iptables -D INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null || true
}

# Conceptual: Create NAT, FORWARD, and INPUT rules on the remote host so TCP traffic destined to ports 80/443
# coming from non-wireguard interfaces is DNAT'd to the target and routed out via the wireguard interface.
# Use SNAT to make sure reply packets return properly. Also open ports 80 and 443 on the VM to public.
add_rules() {
  local wireguard_if="$1"
  local target_ip="$2"
  local local_ts_ip="$3"

  log::debug "Adding iptables rules to route TCP ports 80 and 443 to $target_ip via $wireguard_if (src $local_ts_ip) on $ssh_host"

  # iptables: DNAT prerouting for TCP traffic on ports 80 and 443 coming from non-wireguard interfaces to target IP
  # Command details:
  #   -t nat -A PREROUTING : append a rule to PREROUTING chain in nat table
  #   -p tcp : match TCP protocol
  #   -m multiport --dports 80,443 : match destination ports 80 and 443
  #   "!" -i "$wireguard_if" : match packets incoming on any interface that is NOT wireguard_if
  #   -j DNAT --to-destination "$target_ip" : rewrite destination to target_ip
  run_cmd iptables -t nat -A PREROUTING -p tcp -m multiport --dports 80,443 "!" -i "$wireguard_if" -j DNAT --to-destination "$target_ip"

  # iptables: SNAT postrouting for outgoing wireguard packets to use local wireguard IP as source
  # Command details:
  #   -t nat -A POSTROUTING : append a rule to POSTROUTING chain in nat table
  #   -o "$wireguard_if" : match packets going out via wireguard_if
  #   -j SNAT --to-source "$local_ts_ip" : rewrite source to local_ts_ip
  run_cmd iptables -t nat -A POSTROUTING -o "$wireguard_if" -j SNAT --to-source "$local_ts_ip"

  # iptables: allow forwarding of new/established/related TCP connections from non-wireguard to wireguard (ports 80/443)
  # Command details:
  #   -A FORWARD : append rule to FORWARD chain
  #   "!" -i "$wireguard_if" -o "$wireguard_if" : packets from non-wireguard in to wireguard out
  #   -p tcp -m multiport --dports 80,443 : match tcp dst ports 80 and 443
  #   -m conntrack --ctstate NEW,ESTABLISHED,RELATED : match connection states NEW, ESTABLISHED, RELATED
  #   -j ACCEPT : accept matched packets
  run_cmd iptables -A FORWARD "!" -i "$wireguard_if" -o "$wireguard_if" -p tcp -m multiport --dports 80,443 -m conntrack --ctstate NEW,ESTABLISHED,RELATED -j ACCEPT

  # iptables: allow established/related forwarding from wireguard to non-wireguard
  # Command details:
  #   -A FORWARD : append rule to FORWARD chain
  #   -i "$wireguard_if" "!" -o "$wireguard_if" : packets from wireguard in to non-wireguard out
  #   -m conntrack --ctstate ESTABLISHED,RELATED : only allow established or related connections back
  #   -j ACCEPT : accept matched packets
  run_cmd iptables -A FORWARD -i "$wireguard_if" "!" -o "$wireguard_if" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

  # iptables: allow incoming TCP connections on ports 80 and 443 to the VM itself
  # Command details:
  #   -A INPUT : append a rule to INPUT chain
  #   -p tcp : match TCP protocol
  #   -m multiport --dports 80,443 : match destination ports 80 and 443
  #   -j ACCEPT : accept matched packets
  run_cmd iptables -A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
}

main() {
  if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
    usage
    return 0
  fi

  local cli_if=""
  local cli_target=""
  local cli_ssh=""
  local cli_local_ip=""
  local do_remove=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -s|--ssh-host)
        cli_ssh="$2"
        shift 2
        ;;
      -i|--iface)
        cli_if="$2"
        shift 2
        ;;
      -l|--local-ip)
        cli_local_ip="$2"
        shift 2
        ;;
      -t|--target)
        cli_target="$2"
        shift 2
        ;;
      -r|--remove)
        do_remove="yes"
        shift 1
        ;;
      -h|--help)
        usage
        return 0
        ;;
      *)
        log::error "Unknown argument: $1"
        usage
        return 2
        ;;
    esac
  done

  # Determine SSH host (required), interface and target, preferring CLI -> env -> defaults
  ssh_host="${cli_ssh:-$SSH_HOST}"
  if [[ -z "$ssh_host" ]]; then
    log::error "SSH host not provided. Use -s/--ssh-host or set SSH_HOST environment variable."
    usage
    return 2
  fi

  local wireguard_if="${cli_if:-$TAILSCALE_IF}"
  wireguard_if="${wireguard_if:-wireguard0}"

  local wireguard_target_ip="${cli_target:-$TAILSCALE_TARGET_IP}"

  # The remote host's local wireguard IPv4 is now provided explicitly via CLI or env.
  # This replaces autodetection of the remote interface address.
  local local_ts_ip="${cli_local_ip:-$TAILSCALE_LOCAL_IP}"

  log::info "Configuring iptables routing for interface $wireguard_if on remote host $ssh_host"
  if [[ -n "$do_remove" ]]; then
    log::info "Running in remove mode; will remove rules on remote host $ssh_host"
  fi

  if [[ -z "$local_ts_ip" ]]; then
    log::error "Remote wireguard IPv4 not provided. Use -l/--local-ip or set TAILSCALE_LOCAL_IP environment variable."
    usage
    return 2
  fi

  # Allow overriding TAILSCALE_TARGET_IP via environment or CLI; default to the provided local wireguard IP if unset
  wireguard_target_ip="${wireguard_target_ip:-$local_ts_ip}"
  if [[ -z "$wireguard_target_ip" ]]; then
    log::error "can't determine TAILSCALE_TARGET_IP; set TAILSCALE_TARGET_IP environment variable or provide via -t/--target"
    return 2
  fi

  apply_sysctl

  if [[ -n "$do_remove" ]]; then
    flush_rules "$wireguard_if" "$wireguard_target_ip" "$local_ts_ip"
    log::info "Removed iptables routing for $wireguard_target_ip via $wireguard_if on $ssh_host"
    return 0
  fi

  add_rules "$wireguard_if" "$wireguard_target_ip" "$local_ts_ip"
  log::info "Applied routing for TCP ports 80 and 443 to $wireguard_target_ip via $wireguard_if on $ssh_host (remote wireguard ip: $local_ts_ip)"
}

main "$@"
exit $?
