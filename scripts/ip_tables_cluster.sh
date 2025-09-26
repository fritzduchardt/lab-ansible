FILENAME: tools/tailscale-forward.sh
#!/usr/bin/env bash
set -eo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
source "$SCRIPT_DIR/../lib/log.sh"
source "$SCRIPT_DIR/../lib/utils.sh"

usage() {
  local prog="$1"
  cat <<'USAGE'
Usage:
  tailscale-forward.sh add   --iface <tailscale-iface> --target-ip <ip> --target-port <port> [--proto <tcp|udp>] [--out-if <iface>]
  tailscale-forward.sh remove --iface <tailscale-iface> --target-ip <ip> --target-port <port> [--proto <tcp|udp>] [--out-if <iface>]
  tailscale-forward.sh status --iface <tailscale-iface>

Examples:
  # Forward all TCP traffic arriving on tailscale0:80 to 10.0.0.5:8080, outgoing via eth0
  tailscale-forward.sh add --iface tailscale0 --target-ip 10.0.0.5 --target-port 8080 --proto tcp --out-if eth0

  # Remove the rule created above
  tailscale-forward.sh remove --iface tailscale0 --target-ip 10.0.0.5 --target-port 8080 --proto tcp --out-if eth0

  # Show forwarding/nat rules related to tailscale0
  tailscale-forward.sh status --iface tailscale0
USAGE
}

# Ensure IP forwarding is enabled at the kernel level.
ensure_ip_forwarding() {
  # This sets net.ipv4.ip_forward=1 so the kernel will forward packets between interfaces.
  local _rc
  log::info "Enabling net.ipv4.ip_forward"
  lib::exec sysctl -w net.ipv4.ip_forward=1
  _rc=$?
  if [[ $_rc -ne 0 ]]; then
    log::warning "sysctl returned non-zero ($_rc) while setting ip_forward"
  fi
}

# Add iptables rules to DNAT traffic coming in on a Tailscale interface to target ip:port.
# Conceptual explanation:
#  - Packets arriving on the Tailscale interface destined to a specific port are DNAT'd
#    (destination rewritten) to the internal target IP and port. A corresponding FORWARD
#    rule allows the packet to be forwarded to the target. Optionally, a MASQUERADE rule
#    on the outgoing interface will SNAT the source so return packets route back through this host.
add_forwarding_rules() {
  local iface="$1"
  local target_ip="$2"
  local target_port="$3"
  local proto="$4"
  local out_if="$5"

  log::info "Adding forwarding rules: interface=$iface proto=$proto target=$target_ip:$target_port out_if=$out_if"

  ensure_ip_forwarding

  # The following iptables command manipulates the nat table PREROUTING chain to perform DNAT:
  # -t nat: operate on the nat table
  # -C PREROUTING: check if the rule exists (used in the conditional)
  # -A PREROUTING: append a rule to the PREROUTING chain
  # -i <iface>: match packets arriving on interface <iface>
  # -p <proto>: match protocol (tcp/udp)
  # --dport <port>: match destination port
  # -j DNAT --to-destination <ip>:<port>: jump to DNAT target and rewrite destination to ip:port
  if lib::exec iptables -t nat -C PREROUTING -i "$iface" -p "$proto" --dport "$target_port" -j DNAT --to-destination "$target_ip:$target_port" >/dev/null 2>&1; then
    log::info "DNAT rule already exists in nat PREROUTING for $iface -> $target_ip:$target_port"
  else
    lib::exec iptables -t nat -A PREROUTING -i "$iface" -p "$proto" --dport "$target_port" -j DNAT --to-destination "$target_ip:$target_port"
    log::info "Added DNAT rule in nat PREROUTING for $iface -> $target_ip:$target_port"
  fi

  # The following iptables command manipulates the filter table FORWARD chain to allow forwarded packets:
  # -C FORWARD: check if the rule exists
  # -A FORWARD: append a rule to the FORWARD chain
  # -i <iface>: incoming interface
  # -d <target_ip>: destination ip to match
  # -p <proto> --dport <target_port>: protocol and destination port match
  # -j ACCEPT: accept the matched packet
  if lib::exec iptables -C FORWARD -i "$iface" -d "$target_ip" -p "$proto" --dport "$target_port" -j ACCEPT >/dev/null 2>&1; then
    log::info "FORWARD accept rule already exists for $iface -> $target_ip:$target_port"
  else
    lib::exec iptables -A FORWARD -i "$iface" -d "$target_ip" -p "$proto" --dport "$target_port" -j ACCEPT
    log::info "Added FORWARD accept rule for $iface -> $target_ip:$target_port"
  fi

  if [[ -n "$out_if" ]]; then
    # The following iptables command manipulates the nat table POSTROUTING chain to perform MASQUERADE:
    # -t nat: operate on the nat table
    # -C POSTROUTING: check if the rule exists
    # -A POSTROUTING: append a rule to the POSTROUTING chain
    # -o <out_if>: match packets leaving via <out_if>
    # -j MASQUERADE: rewrite source IP to the outgoing interface IP (useful when target's route would not return directly)
    if lib::exec iptables -t nat -C POSTROUTING -o "$out_if" -j MASQUERADE >/dev/null 2>&1; then
      log::info "POSTROUTING MASQUERADE already exists on $out_if"
    else
      lib::exec iptables -t nat -A POSTROUTING -o "$out_if" -j MASQUERADE
      log::info "Added POSTROUTING MASQUERADE on $out_if"
    fi
  fi
}

# Remove the iptables rules previously added.
remove_forwarding_rules() {
  local iface="$1"
  local target_ip="$2"
  local target_port="$3"
  local proto="$4"
  local out_if="$5"

  log::info "Removing forwarding rules: interface=$iface proto=$proto target=$target_ip:$target_port out_if=$out_if"

  # Remove DNAT rule if exists.
  # See add_forwarding_rules for explanation of arguments.
  if lib::exec iptables -t nat -C PREROUTING -i "$iface" -p "$proto" --dport "$target_port" -j DNAT --to-destination "$target_ip:$target_port" >/dev/null 2>&1; then
    lib::exec iptables -t nat -D PREROUTING -i "$iface" -p "$proto" --dport "$target_port" -j DNAT --to-destination "$target_ip:$target_port"
    log::info "Removed DNAT rule in nat PREROUTING for $iface -> $target_ip:$target_port"
  else
    log::warning "DNAT rule not present for $iface -> $target_ip:$target_port"
  fi

  # Remove FORWARD accept rule if exists.
  if lib::exec iptables -C FORWARD -i "$iface" -d "$target_ip" -p "$proto" --dport "$target_port" -j ACCEPT >/dev/null 2>&1; then
    lib::exec iptables -D FORWARD -i "$iface" -d "$target_ip" -p "$proto" --dport "$target_port" -j ACCEPT
    log::info "Removed FORWARD accept rule for $iface -> $target_ip:$target_port"
  else
    log::warning "FORWARD accept rule not present for $iface -> $target_ip:$target_port"
  fi

  if [[ -n "$out_if" ]]; then
    # Remove MASQUERADE on out_if if present.
    # See add_forwarding_rules for explanation of arguments.
    if lib::exec iptables -t nat -C POSTROUTING -o "$out_if" -j MASQUERADE >/dev/null 2>&1; then
      lib::exec iptables -t nat -D POSTROUTING -o "$out_if" -j MASQUERADE
      log::info "Removed POSTROUTING MASQUERADE on $out_if"
    else
      log::warning "POSTROUTING MASQUERADE not present on $out_if"
    fi
  fi
}

# Show rules relevant to the provided Tailscale interface.
status_rules() {
  local iface="$1"

  log::info "Showing rules related to interface $iface"

  # The following iptables command lists nat table rules in a human-readable (-S) form:
  # -t nat: operate on the nat table
  # -S: print all rules in a format that can be reused (iptables-save style)
  # We filter to rules mentioning the interface or the interface-related chains.
  lib::exec iptables -t nat -S | lib::exec grep -E -- "PREROUTING|POSTROUTING|$iface" || true

  # The following iptables command lists filter table FORWARD chain rules:
  # -S: print rules
  lib::exec iptables -S FORWARD | lib::exec grep -E -- "$iface|$" || true

  # Example of an awk usage: show PREROUTING DNAT rules and extract destination rewrite info.
  # The following awk command:
  # -F ' ' : use space as field separator (default)
  # - '/DNAT/ && /PREROUTING/ {print $0}': for lines matching both 'DNAT' and 'PREROUTING' print the full line
  # This helps to highlight DNAT entries in the PREROUTING chain.
  lib::exec iptables -t nat -S PREROUTING 2>/dev/null | lib::exec awk '/DNAT/ && /PREROUTING/ {print $0}' || true
}

main() {
  if [[ $# -lt 1 ]]; then
    usage "$0"
    exit 2
  fi

  local action="$1"
  shift

  local iface=""
  local target_ip=""
  local target_port=""
  local proto=""
  local out_if=""

  # Default protocol tcp
  proto="${proto:-tcp}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -i|--iface)
        iface="$2"
        shift 2
        ;;
      --target-ip)
        target_ip="$2"
        shift 2
        ;;
      --target-port)
        target_port="$2"
        shift 2
        ;;
      --proto)
        proto="$2"
        shift 2
        ;;
      --out-if)
        out_if="$2"
        shift 2
        ;;
      -h|--help)
        usage "$0"
        exit 0
        ;;
      *)
        log::error "Unknown argument: $1"
        usage "$0"
        exit 2
        ;;
    esac
  done

  # Set defaults if empty
  iface="${iface:-${TAILSCALE_IFACE:-tailscale0}}"
  proto="${proto:-tcp}"

  case "$action" in
    add)
      if [[ -z "$target_ip" || -z "$target_port" ]]; then
        log::error "add requires --target-ip and --target-port"
        usage "$0"
        exit 2
      fi
      add_forwarding_rules "$iface" "$target_ip" "$target_port" "$proto" "$out_if"
      ;;
    remove)
      if [[ -z "$target_ip" || -z "$target_port" ]]; then
        log::error "remove requires --target-ip and --target-port"
        usage "$0"
        exit 2
      fi
      remove_forwarding_rules "$iface" "$target_ip" "$target_port" "$proto" "$out_if"
      ;;
    status)
      status_rules "$iface"
      ;;
    *)
      log::error "Unknown action: $action"
      usage "$0"
      exit 2
      ;;
  esac
}

main "$@"
