#!/usr/bin/env bash
# Firewall for a single Docker host: UFW for the host, DOCKER-USER for containers.
#
# Why both: Docker writes its own iptables rules for published ports, and those
# rules are evaluated before UFW's. So `ufw deny 5432` does NOT protect a container
# started with `-p 5432:5432`. The DOCKER-USER chain is the one place Docker lets
# you filter container traffic yourself, and it survives Docker restarts.
#
# Policy:
#   host:       deny all inbound except SSH (rate-limited), 80 and 443
#   containers: from the internet, only connections to host ports 80/443 get through;
#               container-to-container and outbound traffic are untouched
#
# Dry run by default. Re-run with --apply as root once you have read the plan.
# Keep a second SSH session open while applying, in case you lock yourself out.

set -euo pipefail

APPLY=false
SSH_PORT=22
PUBLIC_PORTS=(80 443)

for arg in "$@"; do
  case "$arg" in
    --apply) APPLY=true ;;
    --ssh-port=*) SSH_PORT="${arg#*=}" ;;
    -h | --help)
      sed -n '2,17p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 2
      ;;
  esac
done

EXT_IF="$(ip route show default | awk '{print $5; exit}')"
if [[ -z "$EXT_IF" ]]; then
  echo "Could not find the default network interface." >&2
  exit 1
fi

AFTER_RULES=/etc/ufw/after.rules
MARK_BEGIN="# BEGIN docker-vps-hardening DOCKER-USER"
MARK_END="# END docker-vps-hardening DOCKER-USER"

docker_user_block() {
  echo "$MARK_BEGIN"
  echo "*filter"
  echo ":DOCKER-USER - [0:0]"
  echo "-F DOCKER-USER"
  echo "-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
  echo "-A DOCKER-USER ! -i $EXT_IF -j RETURN"
  for port in "${PUBLIC_PORTS[@]}"; do
    echo "-A DOCKER-USER -p tcp -m conntrack --ctorigdstport $port --ctdir ORIGINAL -j RETURN"
  done
  echo "-A DOCKER-USER -m limit --limit 3/min -j LOG --log-prefix \"[DOCKER-USER DROP] \""
  echo "-A DOCKER-USER -j DROP"
  echo "COMMIT"
  echo "$MARK_END"
}

run() {
  if $APPLY; then
    echo "+ $*"
    "$@"
  else
    echo "would run: $*"
  fi
}

echo "External interface: $EXT_IF"
echo "SSH port:           $SSH_PORT"
echo "Public ports:       ${PUBLIC_PORTS[*]}"
echo

if $APPLY && [[ $EUID -ne 0 ]]; then
  echo "--apply needs root." >&2
  exit 1
fi

command -v ufw >/dev/null || run apt-get install -y ufw

run ufw default deny incoming
run ufw default allow outgoing
run ufw limit "$SSH_PORT/tcp" comment "SSH, rate-limited"
for port in "${PUBLIC_PORTS[@]}"; do
  run ufw allow "$port/tcp" comment "public web"
done

echo
echo "DOCKER-USER rules to place in $AFTER_RULES:"
docker_user_block | sed 's/^/    /'
echo

if $APPLY; then
  cp "$AFTER_RULES" "$AFTER_RULES.bak.$(date +%Y%m%d%H%M%S)"
  # Replace any previous copy of our block, then append the current one.
  sed -i "/^$MARK_BEGIN\$/,/^$MARK_END\$/d" "$AFTER_RULES"
  docker_user_block >>"$AFTER_RULES"
  run ufw --force enable
  run ufw reload
  echo
  echo "Done. Check from another machine that only ${PUBLIC_PORTS[*]} and $SSH_PORT answer:"
  echo "    nmap -Pn -p- <server-ip>"
else
  echo "Dry run only. Re-run with --apply as root to make these changes."
fi
