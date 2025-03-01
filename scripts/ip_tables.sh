#! /usr/bin/env bash

IP=192.168.0.21

redirect() {
  local source_port="$1"
  local target_port="$2"
  local ip="$3"
  if [[ ! -e /etc/iptables/rules.v4 ]] && ! cat /etc/iptables/rules.v4 | grep "$ip" | grep "$target_port" | grep "$source_port" &>/dev/null; then
    local type="${4:-tcp}"
    sudo iptables -t nat -A OUTPUT -p "$type" -d "$ip" --dport "$source_port" -j DNAT --to-destination "$ip:$target_port"
    return 0
  else
    sudo iptables-restore < /etc/iptables/rules.v4
  fi
  return 1
}

new_rule=
if redirect 80 31474 "$IP"; then
  new_rule=true
fi
if redirect 443 31630 "$IP"; then
  new_rule=true
fi
if redirect 53 30293 "$IP" udp; then
  new_rule=true
fi

if [[ -n "$new_rule" ]]; then
  sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
fi
