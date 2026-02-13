#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[[ -f "${SCRIPT_DIR}/.env" ]] && source "${SCRIPT_DIR}/.env"

: "${VPN_SERVER:?VPN_SERVER is required}"
: "${VPN_CONN:?VPN_CONN is required}"
: "${VPN_LAC:?VPN_LAC is required}"
: "${VPN_PSK:?VPN_PSK is required}"
: "${VPN_USER:?VPN_USER is required}"
: "${VPN_PASS:?VPN_PASS is required}"
: "${VPN_LEFT_ID:?VPN_LEFT_ID is required}"
: "${VPN_RIGHT_ID:?VPN_RIGHT_ID is required}"
: "${VPN_IKE:?VPN_IKE is required}"
: "${VPN_ESP:?VPN_ESP is required}"
: "${VPN_ROUTES:?VPN_ROUTES is required}"

read -ra ROUTES <<< "${VPN_ROUTES}"

IPSEC_CONF="/etc/ipsec.conf"
IPSEC_SECRETS="/etc/ipsec.secrets"
XL2TPD_CONF="/etc/xl2tpd/xl2tpd.conf"
PPP_OPTIONS="/etc/ppp/options.l2tpd.client"

usage() {
    cat <<'EOF'
Usage: l2tp-ipsec-client.sh {up|down|status}

Environment variables (set in .env or export):
  VPN_SERVER    VPN server IP                (required)
  VPN_CONN      IPsec connection name        (required)
  VPN_LAC       L2TP LAC name                (required)
  VPN_PSK       IPsec pre-shared key         (required)
  VPN_USER      PPP username                 (required)
  VPN_PASS      PPP password                 (required)
  VPN_LEFT_ID   Local IPsec ID               (required)
  VPN_RIGHT_ID  Remote IPsec ID              (required)
  VPN_IKE       IKE cipher suite             (required)
  VPN_ESP       ESP cipher suite             (required)
  VPN_ROUTES    Space-separated CIDRs to route via VPN (required)
EOF
    exit 1
}

generate_conf() {
    sudo tee "${IPSEC_CONF}" > /dev/null <<EOF
config setup
  charondebug="ike 1, knl 1, cfg 0"

conn ${VPN_CONN}
  keyexchange=ikev1
  authby=psk
  type=transport
  left=%defaultroute
  leftid=${VPN_LEFT_ID}
  leftprotoport=17/1701
  right=${VPN_SERVER}
  rightprotoport=17/1701
  rightid=${VPN_RIGHT_ID}
  ike=${VPN_IKE}
  esp=${VPN_ESP}
  auto=add
EOF

    sudo tee "${IPSEC_SECRETS}" > /dev/null <<EOF
%any ${VPN_SERVER} : PSK "${VPN_PSK}"
EOF

    sudo tee "${XL2TPD_CONF}" > /dev/null <<EOF
[global]
port = 1701

[lac ${VPN_LAC}]
lns = ${VPN_SERVER}
ppp debug = yes
pppoptfile = ${PPP_OPTIONS}
length bit = yes
EOF

    sudo tee "${PPP_OPTIONS}" > /dev/null <<EOF
ipcp-accept-local
ipcp-accept-remote
refuse-eap
require-chap
noccp
noauth
mtu 1400
mru 1400
persist
maxfail 0
usepeerdns
name ${VPN_USER}
password ${VPN_PASS}
EOF
}

clean_conf() {
    sudo rm -f "${IPSEC_CONF}" "${IPSEC_SECRETS}" "${XL2TPD_CONF}" "${PPP_OPTIONS}"
}

case "${1}" in
    up)
        generate_conf
        sudo ipsec start
        sleep 1
        sudo ipsec up "${VPN_CONN}"
        sudo systemctl start xl2tpd
        sudo bash -c "echo 'c ${VPN_LAC}' > /var/run/xl2tpd/l2tp-control"
        echo "Waiting for ppp0 IPv4..."
        for i in $(seq 1 15); do
            if ip -4 addr show ppp0 2>/dev/null | grep -q inet; then
                break
            fi
            sleep 1
        done
        if ! ip -4 addr show ppp0 2>/dev/null | grep -q inet; then
            echo "ERROR: ppp0 did not get IPv4 within 15s"
            exit 1
        fi

        for route in "${ROUTES[@]}"; do
            sudo ip route add "${route}" dev ppp0 2>/dev/null || true
        done

        echo "VPN is up (split-tunnel)."
        ip addr show ppp0
        echo ""
        echo "Routes via ppp0:"
        ip route show dev ppp0
        ;;
    down)
        sudo bash -c "echo 'd ${VPN_LAC}' > /var/run/xl2tpd/l2tp-control" 2>/dev/null || true
        sudo systemctl stop xl2tpd 2>/dev/null || true
        sudo ipsec down "${VPN_CONN}" 2>/dev/null || true
        sudo ipsec stop 2>/dev/null || true
        for route in "${ROUTES[@]}"; do
            sudo ip route del "${route}" dev ppp0 2>/dev/null || true
        done
        clean_conf
        echo "VPN is down. Config files removed."
        ;;
    status)
        echo "=== IPsec ==="
        sudo ipsec status 2>/dev/null || echo "IPsec not running"
        echo ""
        echo "=== xl2tpd ==="
        systemctl is-active xl2tpd 2>/dev/null || echo "xl2tpd not running"
        echo ""
        echo "=== ppp0 ==="
        ip addr show ppp0 2>/dev/null || echo "ppp0 does not exist"
        echo ""
        echo "=== Routes via ppp0 ==="
        ip route show dev ppp0 2>/dev/null || echo "No routes"
        ;;
    *)
        usage
        ;;
esac
