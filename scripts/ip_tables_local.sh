#! /usr/bin/env bash

IP=192.168.0.21

redirect() {
  local source_port="$1"
  local target_port="$2"
  local ip="$3"
  local type="${4:-tcp}"
  set -x
  sudo iptables -t nat -A OUTPUT -p "$type" -d "$ip" --dport "$source_port" -j DNAT --to-destination "$ip:$target_port"
  set +x
}

sudo rm /etc/iptables/rules.v4
sudo iptables -t nat -F

# nginx http
if ! redirect 80 32564 "$IP"; then
  echo "Failed to install nginx http"
fi
# nginx https
if ! redirect 443 30895 "$IP"; then
  echo "Failed to install nginx https"
fi
# pihole
if ! redirect 53 32537 "$IP" udp; then
  echo "Failed to install pihole"
fi

sudo iptables-save | sudo tee /etc/iptables/rules.v4 >/dev/null
