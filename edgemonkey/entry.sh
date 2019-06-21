#!/bin/bash

trap cleanup EXIT INT HUP

INTERFACE="$(ip addr | awk '/'"$(curl -sq -X GET --header "Content-Type:application/json" \
"${BALENA_SUPERVISOR_ADDRESS}/v1/device?apikey=${BALENA_SUPERVISOR_API_KEY}" | jq -r .ip_address)"'/{print $NF}')"

# come from ENV
# values
CHAOS=${CHAOS:-true} # bool
GLOBAL_TIMEOUT=${GLOBAL_TIMEOUT:-1000} # s
GLOBAL_REFRESH=${GLOBAL_REFRESH:-10} # s
THROTTLE=${THROTTLE_VALUE:-250} # ms
UPLOAD_LIMIT=${UPLOAD_LIMIT:-500} # Kbps
DOWNLOAD_LIMIT=${DOWNLOAD_LIMIT:-500} # Kbps
PERC_DROP=${PERC_DROP:-5} # %
TC_CORRELATION=${TC_CORRELATION:-25} # %
BANDWIDTH_MAX=${BANDWIDTH_MAX:-9999999} # Kbps

# frequencies
THROTTLE_FREQ=${THROTTLE_FREQ:-25}
PACKET_DROP_FREQ=${PACKET_DROP_FREQ:-25}
DNS_DROP_FREQ=${DNS_DROP_FREQ:-25}
RANDOM_SUBNET_FREQ=${RANDOM_SUBNET_FREQ:-25}
LOCKFILE_FREQ=${LOCKFILE_FREQ:-25}
FORCED_UPDATE_FREQ=${FORCED_UPDATE_FREQ:-25}
RANDOM_SERVICE_RESTART_RESTART_FREQ=${RANDOM_SERVICE_RESTART_RESTART_FREQ:-25}
BANDWIDTH_LIMIT_FREQ=${BANDWIDTH_LIMIT_FREQ:-25}

function global_throttle_traffic() {
    echo "throttling traffic globally to ${THROTTLE}.."
    tc qdisc replace dev "${INTERFACE}" root netem delay "${THROTTLE}ms" "$(( THROTTLE / 10 ))ms" "${TC_CORRELATION}%"
    echo "Throttle applied"
}

function global_drop_packets() {
    echo "dropping ${PERC_DROP}% of packets routed to ${INTERFACE}.."
    tc qdisc replace dev "${INTERFACE}" root netem loss "${PERC_DROP}%" "${TC_CORRELATION}%"
    echo "Packet drop applied"
}

function global_restore_packet_drop() {
    echo "removing global packet loss to ${INTERFACE}.."
    tc qdisc replace dev "${INTERFACE}" root netem loss 0%
    echo "Packet loss removed"
}

function global_restore_throttle() {
    echo "undoing global throttle.."
    tc qdisc replace dev "${INTERFACE}" root netem delay 0ms
    echo "Throttle undone"
}

function restart_unit(){
    echo "restarting $1.."
    DBUS_SYSTEM_BUS_ADDRESS=unix:path=/host/run/dbus/system_bus_socket dbus-send --system --print-reply \
    --dest=org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.systemd1.Manager.RestartUnit string:"$1" \
    string:"replace"
    echo "$1 restarted.."
}

function restart_supervisor() {
    restart_unit "resin-supervisor.service"
}

function restart_vpn() {
    restart_unit "openvpn.service"
}

function restart_network() {
    restart_unit "NetworkManager.service"
}

function restart_dns() {
    restart_unit "dnsmasq.service"
}

function restart_timesync() {
    restart_unit "chronyd.service"
}

function restart_engine() {
    restart_unit "balena.service"
}

function force_update(){
    echo "forcing an app update from the supervisor..."
    curl -X POST --header "Content-Type:application/json" \
    --data '{"force": true}' \
    "$BALENA_SUPERVISOR_ADDRESS/v1/update?apikey=$BALENA_SUPERVISOR_API_KEY"
}

function restart_app() {
    curl -X POST --header "Content-Type:application/json" \
    --data "{\"appId\": $1}" \
    "${BALENA_SUPERVISOR_ADDRESS}/v1/restart?apikey=${BALENA_SUPERVISOR_API_KEY}"
}

function stop_app() {
    curl -X POST --header "Content-Type:application/json" \
    "${BALENA_SUPERVISOR_ADDRESS}/v1/apps/$1/stop?apikey=${BALENA_SUPERVISOR_API_KEY}"
}

function restart_all_apps() {
    curl -X POST --header "Content-Type:application/json" \
    --data "{\"appId\": $1}" \
    "${BALENA_SUPERVISOR_ADDRESS}/v1/restart?apikey=${BALENA_SUPERVISOR_API_KEY}"
}

function drop_dns() {
    echo "dropping all DNS traffic.."
    iptables -A OUTPUT -p udp -m udp --dport 53 -j DROP -m comment --comment "DNS_DROP_OUT"
    iptables -A INPUT -p udp -m udp --dport 53 -j DROP -m comment --comment "DNS_DROP_IN"
    echo "DNS filters applied"
}

function drop_random_subnet() {
    random_subnet="$(( RANDOM % 256 )).$(( RANDOM % 256 )).$(( RANDOM % 256 )).$(( RANDOM % 256 ))/$(( (RANDOM % 24)+8))"
    echo "dropping all traffic to $random_subnet.."
    iptables -A OUTPUT -j DROP -s "$random_subnet" -m comment --comment "RANDOM_SUBNET_OUT"
    iptables -A INPUT -j DROP -s "$random_subnet" -m comment --comment "RANDOM_SUBNET_IN"
    echo "Traffic to $random_subnet dropped"
}

function restore_random_subnets() {
    echo "restoring random subnet traffic.."
    comment="RANDOM_SUBNET"
    RAND="${1:-$RANDOM}"
    case "$(( RAND % 3 ))" in
        "0")
            echo "restoring ALL random subnet traffic.."
            iptables-save | grep -v "${comment}" | iptables-restore
            ;;
        "1")
            echo "restoring INBOUND random subnet traffic.."
            iptables-save | grep -v "${comment}_IN" | iptables-restore
            ;;
        "2")
            echo "restoring OUTBOUND random subnet traffic.."
            iptables-save | grep -v "${comment}_OUT" | iptables-restore
            ;;
    esac
    echo "random subnet filters removed"
}

function global_restore_bandwidth(){
    echo "removing all bandwidth limits.."
    wondershaper "${INTERFACE}" clear
}

function global_limit_bandwidth(){
    RAND="${RANDOM}"
    case "$(( RAND % 3 ))" in
        "0")
            echo "limiting upload and download bandwidth.."
            wondershaper "${INTERFACE}" "${UPLOAD_LIMIT}" "${DOWNLOAD_LIMIT}"
            ;;
        "1")
            echo "limiting ONLY download bandwidth.."
            wondershaper "${INTERFACE}" "${BANDWIDTH_MAX}" "${DOWNLOAD_LIMIT}"
            ;;
        "2")
            echo "limiting ONLY upload bandwidth.."
            wondershaper "${INTERFACE}" "${UPLOAD_LIMIT}" "${BANDWIDTH_MAX}"
            ;;
    esac
}

function restore_dns() {
    echo "restoring DNS traffic.."
    comment="DNS_DROP"
    RAND="${1:-$RANDOM}"
    case "$(( RAND % 3 ))" in
        "0")
            echo "restoring ALL DNS traffic.."
            iptables-save | grep -v "${comment}" | iptables-restore
            ;;
        "1")
            echo "restoring INBOUND DNS traffic.."
            iptables-save | grep -v "${comment}_IN" | iptables-restore
            ;;
        "2")
            echo "restoring OUTBOUND DNS traffic.."
            iptables-save | grep -v "${comment}_OUT" | iptables-restore
            ;;
    esac
    echo "DNS filters removed"
}

function take_application_lock() {
    echo "taking lock at $BALENA_APP_LOCK_PATH"
    lockfile-create --use-pid --lock-name "$BALENA_APP_LOCK_PATH"
    echo "took lock at $BALENA_APP_LOCK_PATH"
}

function remove_application_lock() {
    echo "removing lock at $BALENA_APP_LOCK_PATH"
    lockfile-remove --lock-name "$BALENA_APP_LOCK_PATH"
    echo "removed lock at $BALENA_APP_LOCK_PATH"
}
function cleanup() {
    # passing a 0 restores all DNS traffic
    restore_dns 0
    restore_random_subnets 0
    global_restore_packet_drop
    global_restore_bandwidth
    global_restore_throttle
    remove_application_lock
}

echo "INTERFACE set to ${INTERFACE}"

# initialize some states
dns_drop_applied=false
random_subnet_drop_applied=false
global_traffic_throttled=false
global_bandwidth_limited=false
global_packet_drop=false
global_iter_count=0

while "${CHAOS}" ; do
    RAND="${RANDOM}"
    if [ $(( RAND % DNS_DROP_FREQ )) -eq 0 ]; then
        if $dns_drop_applied; then
            dns_drop_applied=false
            restore_dns
        else
            dns_drop_applied=true
            drop_dns
        fi
    elif [ $(( RAND % PACKET_DROP_FREQ )) -eq 1 ]; then
        if $global_packet_drop; then
            global_packet_drop=false
            global_restore_packet_drop
        else
            global_packet_drop=true
            global_drop_packets
        fi
    elif [ $(( RAND % BANDWIDTH_LIMIT_FREQ )) -eq 2 ]; then
        if $global_bandwidth_limited; then
            global_bandwidth_limited=false
            global_restore_bandwidth
        else
            global_bandwidth_limited=true
            global_limit_bandwidth
        fi
    elif [ $(( RAND % THROTTLE_FREQ )) -eq 3 ]; then
        if $global_traffic_throttled; then
            global_traffic_throttled=false
            global_restore_throttle
        else
            global_traffic_throttled=true
            global_throttle_traffic
        fi
    elif [ $(( RAND % RANDOM_SUBNET_FREQ )) -eq 4 ]; then
        if $random_subnet_drop_applied; then
            random_subnet_drop_applied=false
            restore_random_subnets
        else
            random_subnet_drop_applied=true
            drop_random_subnet
        fi
    elif [ $(( RAND % LOCKFILE_FREQ )) -eq 5 ]; then
        if lockfile-check "$BALENA_APP_LOCK_PATH"; then
            remove_application_lock
        else
            take_application_lock
        fi
    elif [ $(( RAND % FORCED_UPDATE_FREQ )) -eq 6 ]; then
        force_update
    elif [ $(( RAND % RANDOM_SERVICE_RESTART_RESTART_FREQ )) -eq 7 ]; then
        case "$(( RAND % RANDOM_SERVICE_RESTART_RESTART_FREQ ))" in
            "0")
                restart_engine
                ;;
            "1")
                restart_timesync
                ;;
            "2")
                restart_dns
                ;;
            "3")
                restart_vpn
                ;;
            "4")
                restart_network
                ;;
            "5")
                restart_supervisor
                ;;
        esac
    fi
    global_iter_count=$(( global_iter_count + 1 ))
    echo "iteration ${global_iter_count}"
    if [[ $GLOBAL_TIMEOUT -gt 0 ]]; then
        if [[ $(( global_iter_count * GLOBAL_REFRESH )) -ge $GLOBAL_TIMEOUT ]]; then
            echo "global limit reached, suspending actions after cleanup"
            cleanup
            echo "sleeping indefinitely"
            sleep infinity
        else
            sleep "${GLOBAL_REFRESH}"
        fi
    else
        sleep "${GLOBAL_REFRESH}"
    fi
done
