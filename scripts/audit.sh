#!/usr/bin/env bash
# Read-only security check for a Docker host. Changes nothing.
# Prints PASS / WARN / FAIL lines and exits non-zero if anything failed,
# so it can run from cron or CI and alert you.
#
#   sudo ./scripts/audit.sh
#
# Allowed public ports can be overridden: ALLOWED_PORTS="22 80 443" ./scripts/audit.sh

set -uo pipefail

ALLOWED_PORTS="${ALLOWED_PORTS:-22 80 443}"
fails=0
warns=0

pass() { printf '  PASS  %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  FAIL  %s\n' "$*"; fails=$((fails + 1)); }
allowed() { [[ " $ALLOWED_PORTS " == *" $1 "* ]]; }

echo "Listening sockets"
# Anything bound to all interfaces that is not on the allow-list is exposed
# (unless a firewall stops it, which the next sections check).
while read -r addr; do
  port="${addr##*:}"
  host="${addr%:*}"
  case "$host" in
    0.0.0.0 | '*' | '[::]')
      if allowed "$port"; then pass "port $port open on all interfaces (allowed)"; else fail "port $port open on all interfaces"; fi
      ;;
  esac
done < <(ss -H -tln | awk '{print $4}' | sort -u)

echo "Docker published ports"
if command -v docker >/dev/null; then
  while read -r name ports; do
    [[ -z "$ports" ]] && continue
    # Word-splitting is intended: "a, b" -> "a" "b".
    # shellcheck disable=SC2086
    for mapping in ${ports//,/ }; do
      if [[ "$mapping" == 0.0.0.0:* || "$mapping" == "[::]:"* || "$mapping" == :::* ]]; then
        # "0.0.0.0:8080->80/tcp" -> "0.0.0.0:8080" -> "8080" (ranges keep their first port)
        host_part="${mapping%%->*}"
        host_port="${host_part##*:}"
        host_port="${host_port%%-*}"
        if allowed "$host_port"; then pass "$name publishes $mapping"; else fail "$name publishes $mapping to the internet; bind it to 127.0.0.1 or drop the port"; fi
      fi
    done
  done < <(docker ps --format '{{.Names}} {{.Ports}}')
else
  warn "docker not found; skipped"
fi

echo "Firewall"
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  pass "ufw is active"
else
  fail "ufw is not active"
fi
if iptables -S DOCKER-USER 2>/dev/null | grep -q -- '-j DROP'; then
  pass "DOCKER-USER chain drops unlisted container traffic"
else
  fail "DOCKER-USER has no DROP rule: published container ports bypass ufw"
fi

echo "SSH"
if command -v sshd >/dev/null; then
  cfg="$(sshd -T 2>/dev/null)"
  check_ssh() {
    local key="$1" good="$2" value
    value="$(awk -v k="$key" '$1==k {print $2}' <<<"$cfg")"
    if [[ " $good " == *" $value "* ]]; then pass "$key $value"; else fail "$key is '$value' (want: $good)"; fi
  }
  check_ssh passwordauthentication "no"
  check_ssh kbdinteractiveauthentication "no"
  check_ssh permitrootlogin "no prohibit-password without-password"
  check_ssh x11forwarding "no"
else
  warn "sshd not found; skipped"
fi

echo "Updates"
if dpkg -s unattended-upgrades >/dev/null 2>&1; then
  pass "unattended-upgrades installed"
else
  warn "unattended-upgrades not installed: security patches depend on someone remembering"
fi

echo
echo "Summary: $fails failed, $warns warnings"
[[ $fails -eq 0 ]]
