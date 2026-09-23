#!/usr/bin/env bash
# Print a human-readable summary of this Linux computer's hardware and network.
set -uo pipefail

# Network speed testing is optional because it contacts an external service.
run_speedtest=false
if [[ "${1:-}" == "--speedtest" ]]; then
    run_speedtest=true
elif [[ $# -gt 0 ]]; then
    printf 'Usage: %s [--speedtest]\n' "$0" >&2
    exit 2
fi

have() { command -v "$1" >/dev/null 2>&1; }
value_or_na() { [[ -n "${1:-}" ]] && printf '%s' "$1" || printf 'Not available'; }
human_bytes() {
    local bytes=${1:-}
    [[ "$bytes" =~ ^[0-9]+$ ]] || { printf 'Not available'; return; }
    awk -v n="$bytes" 'BEGIN { split("B KiB MiB GiB TiB",u," "); i=1; while (n>=1024 && i<5) { n/=1024; i++ } printf "%.2f %s", n, u[i] }'
}

username=$(id -un 2>/dev/null || true)
user_id=$(id -u 2>/dev/null || true)
group_id=$(id -g 2>/dev/null || true)
whoami_string="User: $(value_or_na "$username"), User ID: $(value_or_na "$user_id"), Group ID: $(value_or_na "$group_id")"
uptime_seconds=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || true)
uptime_days=uptime_months=uptime_hours=uptime_minutes=uptime_secs='Not available'
uptime_total_days='Not available'
if [[ "$uptime_seconds" =~ ^[0-9]+$ ]]; then
    uptime_total_days=$((uptime_seconds / 86400))
    uptime_days=$((uptime_total_days % 30))
    uptime_months=$((uptime_total_days / 30))
    uptime_hours=$(((uptime_seconds % 86400) / 3600))
    uptime_minutes=$(((uptime_seconds % 3600) / 60))
    uptime_secs=$((uptime_seconds % 60))
fi

cpu_name=$(awk -F ': ' '/model name/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
cpu_model=$(awk -F ': ' '/^ model[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
[[ -n "$cpu_model" ]] || cpu_model=$(awk -F ': ' '/^CPU part/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)
cpu_temp=''
for thermal in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$thermal" ]] || continue
    raw=$(cat "$thermal" 2>/dev/null || true)
    if [[ "$raw" =~ ^[0-9]+$ ]]; then cpu_temp=$(awk -v n="$raw" 'BEGIN {printf "%.1f", n/1000}'); break; fi
done
[[ -n "$cpu_temp" ]] || cpu_temp=$(sensors 2>/dev/null | awk '/Package id 0:|Tctl:|CPU Temperature:/ {gsub(/[+°C]/,"",$NF); print $NF; exit}' || true)
if [[ -n "$cpu_temp" ]]; then cpu_temp_display="${cpu_temp}°C"; else cpu_temp_display='Not available'; fi
cpu_clock=$(awk -F ': ' '/cpu MHz/ {printf "%.0f MHz", $2; exit}' /proc/cpuinfo 2>/dev/null || true)
cpu_mfg=$(awk -F ': ' '/vendor_id|CPU implementer/ {print $2; exit}' /proc/cpuinfo 2>/dev/null || true)

ram_total=$(awk '/^MemTotal:/ {printf "%.0f", $2*1024}' /proc/meminfo 2>/dev/null || true)
ram_free=$(awk '/^MemAvailable:/ {printf "%.0f", $2*1024}' /proc/meminfo 2>/dev/null || true)
ram_used=''
if [[ "$ram_total" =~ ^[0-9]+$ && "$ram_free" =~ ^[0-9]+$ ]]; then ram_used=$((ram_total-ram_free)); fi
swap_total=$(awk '/^SwapTotal:/ {printf "%.0f", $2*1024}' /proc/meminfo 2>/dev/null || true)
ram_model=$(sudo -n dmidecode --type memory 2>/dev/null | awk -F ': *' '/^[[:space:]]*Size:/ {print $2; exit}' || true)

mapfile -t disk_rows < <(lsblk -dn -o NAME,TYPE 2>/dev/null | awk '$2=="disk" {print $1}')
disk_count=${#disk_rows[@]}
disk_names=$(printf '%s\n' "${disk_rows[@]}" | sed '/^$/d' | paste -sd ', ' -)
disk_space=$(df -B1 --output=size,used,avail / 2>/dev/null | awk 'NR==2 {printf "%s|%s|%s",$1,$2,$3}')
disk_total=$(cut -d'|' -f1 <<<"$disk_space")
disk_used=$(cut -d'|' -f2 <<<"$disk_space")
disk_free=$(cut -d'|' -f3 <<<"$disk_space")
disk_health='Not available'
disk_temp=''
if have smartctl; then
    for name in "${disk_rows[@]}"; do
        smart=$(sudo -n smartctl -H -A "/dev/$name" 2>/dev/null || true)
        if grep -q 'PASSED' <<<"$smart"; then disk_health='100'; fi
        t=$(awk '/Temperature_Celsius|Temperature:/ {for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+$/) v=$i} END {print v}' <<<"$smart")
        [[ -n "$t" ]] && disk_temp=$t
        break
    done
fi
if [[ "$disk_health" == 'Not available' ]]; then disk_health_display='Not available'; else disk_health_display="${disk_health}%"; fi
if [[ -n "$disk_temp" ]]; then disk_temp_display="${disk_temp}°C"; else disk_temp_display='Not available'; fi

mapfile -t external_rows < <(lsblk -P -o NAME,TRAN,TYPE 2>/dev/null | awk '/TRAN="usb"/ && /TYPE="disk"/')
external_count=${#external_rows[@]}
external_names=''
external_ports=''
for row in "${external_rows[@]}"; do
    name=$(sed -n 's/.*NAME="\([^"]*\)".*/\1/p' <<<"$row")
    external_names+="${external_names:+, }$name"
    external_ports+="${external_ports:+, }USB"
done

ips=$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}' | paste -sd ', ' -)
cidrs=$(ip -o -4 addr show scope global 2>/dev/null | awk '{print $4}' | paste -sd ', ' -)
gateways=$(ip route show default 2>/dev/null | awk '{print $3}' | paste -sd ', ' -)
vpn_check='FALSE'
vpn_ips=''
vpn_cidrs=''
vpn_gateway=''
while IFS= read -r line; do
    dev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' <<<"$line")
    [[ "$dev" =~ (tun|tap|wg|vpn|ppp) ]] || continue
    vpn_check='TRUE'
    addr=$(ip -o -4 addr show dev "$dev" scope global 2>/dev/null | awk '{print $4}' | paste -sd ', ' -)
    route=$(ip route show default dev "$dev" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}' | paste -sd ', ' -)
    vpn_ips+="${vpn_ips:+, }${addr:-Not available}"
    vpn_cidrs+="${vpn_cidrs:+, }${addr:-Not available}"
    vpn_gateway+="${vpn_gateway:+, }${route:-Not available}"
done < <(ip route show 2>/dev/null)
[[ -n "$vpn_ips" ]] || vpn_ips='Not available'
[[ -n "$vpn_cidrs" ]] || vpn_cidrs='Not available'
[[ -n "$vpn_gateway" ]] || vpn_gateway='Not available'

download_speed=''
upload_speed=''
if [[ "$run_speedtest" == true ]]; then
    if have speedtest-cli; then
        speed_result=$(speedtest-cli --simple 2>/dev/null || true)
        download_speed=$(awk -F ': ' '/Download:/ {print $2; exit}' <<<"$speed_result")
        upload_speed=$(awk -F ': ' '/Upload:/ {print $2; exit}' <<<"$speed_result")
    elif have speedtest; then
        speed_result=$(speedtest --accept-license --accept-gdpr -f human-readable 2>/dev/null || true)
        download_speed=$(awk -F ': ' '/Download:/ {print $2; exit}' <<<"$speed_result")
        upload_speed=$(awk -F ': ' '/Upload:/ {print $2; exit}' <<<"$speed_result")
    fi
fi
nic_speed=''
default_iface=$(ip route show default 2>/dev/null | awk '/dev/ {for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
if [[ -n "$default_iface" ]] && have ethtool; then nic_speed=$(ethtool "$default_iface" 2>/dev/null | awk -F ': ' '/Speed:/ {print $2; exit}'); fi

port_numbers=()
port_types=()
port_versions=()
port_speeds=()
usb_logical_ports=0
while IFS= read -r hub_line; do
    [[ "$hub_line" == *Class=root_hub* ]] || continue
    bus=$(sed -n 's#.*Bus \([0-9][0-9]*\)\.Port.*#\1#p' <<<"$hub_line")
    hub_ports=$(sed -n 's#.*Driver=[^/]*/\([0-9][0-9]*\)p.*#\1#p' <<<"$hub_line")
    [[ "$hub_ports" == 1 ]] && hub_port_word='port' || hub_port_word='ports'
    link_speed=$(awk '{print $NF}' <<<"$hub_line")
    [[ "$hub_ports" =~ ^[0-9]+$ ]] && usb_logical_ports=$((usb_logical_ports + hub_ports))
    case "$link_speed" in
        480M) usb_version='USB 2.0'; usb_max_speed='480 Mb/s' ;;
        5000M) usb_version='USB 3.0 / 3.1 Gen 1'; usb_max_speed='5 Gb/s' ;;
        10000M) usb_version='USB 3.1 Gen 2 / USB 3.2 Gen 2x1'; usb_max_speed='10 Gb/s' ;;
        20000M) usb_version='USB 3.2 Gen 2x2'; usb_max_speed='20 Gb/s' ;;
        *) usb_version='Not available'; usb_max_speed='Not available' ;;
    esac
    port_numbers+=("USB bus ${bus:-?}")
    port_types+=("USB root hub (${hub_ports:-?} reported ${hub_port_word:-ports})")
    port_versions+=("$usb_version")
    port_speeds+=("$usb_max_speed")
done < <(lsusb -t 2>/dev/null || true)

gpu_model=$(lspci 2>/dev/null | awk -F ': ' '/VGA compatible controller|3D controller|Display controller/ {print $NF; exit}' || true)
for connector in /sys/class/drm/card*-*; do
    [[ -r "$connector/status" ]] || continue
    connector_name=${connector##*/}
    connector_type=${connector_name#*-}
    connector_status=$(cat "$connector/status" 2>/dev/null || true)
    case "$connector_type" in
        HDMI-A-*) connector_type="HDMI ($connector_type, ${connector_status:-status unknown})" ;;
        DP-*) connector_type="DisplayPort ($connector_type, ${connector_status:-status unknown})" ;;
        DVI-*) connector_type="DVI ($connector_type, ${connector_status:-status unknown})" ;;
        VGA-*) connector_type="VGA ($connector_type, ${connector_status:-status unknown})" ;;
        eDP-*) connector_type="Embedded DisplayPort ($connector_type, ${connector_status:-status unknown})" ;;
        *) connector_type="$connector_type (${connector_status:-status unknown})" ;;
    esac
    port_numbers+=("Display connector $(( ${#port_numbers[@]} + 1 ))")
    port_types+=("$connector_type")
    port_versions+=('Not available')
    port_speeds+=('Not available')
done

ports_count=${#port_numbers[@]}

report=$(cat <<REPORT
PC System Information
=====================

Identity:
Username: $(value_or_na "$username")
Who Am I: $whoami_string
Uptime:
  Days: $uptime_days
  Months: $uptime_months
  Total Days: $uptime_total_days
  Hours: $uptime_hours
  Minutes: $uptime_minutes
  Seconds: $uptime_secs

CPU:
  Name: $(value_or_na "$cpu_name")
  Model: $(value_or_na "$cpu_model")
  Temperature: $cpu_temp_display
  Clock Rate: $(value_or_na "$cpu_clock")
  Day of Manufacture: $(value_or_na "$cpu_mfg")

RAM:
  Name: $(value_or_na "$ram_model")
  Model: $(value_or_na "$ram_model")
  Total: $(human_bytes "$ram_total")
  Used: $(human_bytes "$ram_used")
  Free: $(human_bytes "$ram_free")
  Swap: $(human_bytes "$swap_total")

DISK:
  Number of Disks: $disk_count
  Disk Name: $(value_or_na "$disk_names")
  Health: $disk_health_display
  Total Space (root filesystem): $(human_bytes "$disk_total")
  Usage: $(human_bytes "$disk_used")
  Free Space: $(human_bytes "$disk_free")
  Temperature: $disk_temp_display

EXTERNAL Disk:
  Port Connected: $(value_or_na "$external_ports")
  Number of Disks: $external_count
  Disk Name: $(value_or_na "$external_names")
  Health: Not available
  Total Space: Not available
  Usage: Not available
  Free Space: Not available

Network:
  IPs: $(value_or_na "$ips")
  CIDR: $(value_or_na "$cidrs")
  Gateway: $(value_or_na "$gateways")

VPN Check:
  Result: $vpn_check
If VPN Used:
  IPs: $vpn_ips
  CIDR: $vpn_cidrs
  Gateway: $vpn_gateway
  Connection Speed: $(value_or_na "$nic_speed")
  Download Speed: $(value_or_na "$download_speed")
  Upload Speed: $(value_or_na "$upload_speed")

NIC Test:
  Maximum Speed Transfer Files: $(value_or_na "$nic_speed")
  Upload: $(value_or_na "$upload_speed")
  Download: $(value_or_na "$download_speed")

PC Ports:
  Number of Detected Port Entries (USB hubs + display connectors): $ports_count
  Physical Port Count: Not reliably exposed by the operating system
  Graphics Adapter: $(value_or_na "$gpu_model")
  USB Root Hub Downstream Ports (reported, may overlap): $usb_logical_ports
  Port Number | Port Type | Version | Maximum Speed
  ------------|-----------|---------|--------------
$(for i in "${!port_numbers[@]}"; do printf '  %s | %s | %s | %s\n' "${port_numbers[$i]}" "${port_types[$i]}" "${port_versions[$i]}" "${port_speeds[$i]}"; done)
REPORT
)

# Use ANSI colors in an interactive terminal; redirected output stays plain.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    printf '%s\n' "$report" | awk '
        /^PC System Information$/ || /^[A-Z][A-Za-z ]*:?$/ {
            printf "\033[1;36m%s\033[0m\n", $0; next
        }
        /^[[:space:]]*[^:]+:/ {
            line=$0; sub(/^[[:space:]]*/, "", line)
            split(line, parts, ":")
            indent=$0; sub(/[^[:space:]].*$/, "", indent)
            label=parts[1] ":"
            value=line; sub(/^[^:]+:[[:space:]]*/, "", value)
            printf "%s\033[32m%s\033[0m \033[33m%s\033[0m\n", indent, label, value; next
        }
        {print}
    '
else
    printf '%s\n' "$report"
fi

# Create an organized HTML report with a summary table per section and a dedicated ports table.
html_file='pc-extract-info-report.html'
html_escape() {
    sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' <<<"$1" | tr -d '\n'
}
if ! {
    cat <<'HTML_HEAD'
<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PC System Information</title>
<style>
body{font:13pt/1.5 sans-serif;color:#17324d;background:#f3f7fb;margin:2rem}
h1{color:#075985;font-size:21pt;margin-bottom:.25rem}h2{font-size:15pt;color:#087e8b;margin:1.5rem 0 .5rem}
.note{color:#526579;font-size:11pt;margin-bottom:1.5rem}
table{width:100%;border-collapse:collapse;background:white;margin-bottom:1.25rem;box-shadow:0 1px 5px #d5e0e8}
th,td{text-align:left;padding:.65rem .8rem;border-bottom:1px solid #e2eaf0;font-size:13pt;vertical-align:top}
th{width:29%;color:#2457a7;background:#edf5fb;font-weight:600}td{color:#18794e}
thead th{width:auto;color:white;background:#087e8b}tbody tr:nth-child(even){background:#f8fbfd}
</style></head><body>
<h1>PC System Information</h1>
<div class="note">Values are collected from operating-system interfaces. Port counts, versions, and speeds are shown only when the system exposes them.</div>
HTML_HEAD
    table_open=false
    in_ports=false
    while IFS= read -r line; do
        case "$line" in
            'PC System Information'|'====================='|'') continue ;;
            'Identity:'|'Uptime:'|'CPU:'|'RAM:'|'DISK:'|'EXTERNAL Disk:'|'Network:'|'VPN Check:'|'If VPN Used:'|'NIC Test:'|'PC Ports:')
                if [[ "$table_open" == true ]]; then printf '</tbody></table>\n'; fi
                printf '<h2>%s</h2>\n' "$(html_escape "${line%:}")"
                table_open=true
                [[ "$line" == 'PC Ports:' ]] && in_ports=true || in_ports=false
                if [[ "$in_ports" == true ]]; then
                    printf '<table><thead><tr><th>Port Number</th><th>Port Type</th><th>Version</th><th>Maximum Speed</th></tr></thead><tbody>\n'
                else
                    printf '<table><tbody>\n'
                fi
                continue
                ;;
        esac

        trimmed=${line#  }
        if [[ "$in_ports" == true && "$trimmed" == Port\ Number\ \|* ]]; then continue; fi
        if [[ "$in_ports" == true && "$trimmed" == ------------* ]]; then continue; fi
        if [[ "$in_ports" == true && "$trimmed" == *' | '* ]]; then
            IFS='|' read -r col1 col2 col3 col4 <<<"$trimmed"
            printf '<tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
                "$(html_escape "${col1% }")" "$(html_escape "${col2# }")" \
                "$(html_escape "${col3# }")" "$(html_escape "${col4# }")"
            continue
        fi
        if [[ "$line" == *:* ]]; then
            label=${trimmed%%:*}
            value=${trimmed#*: }
            if [[ "$in_ports" == true ]]; then
                printf '<tr><th colspan="2">%s</th><td colspan="2">%s</td></tr>\n' "$(html_escape "$label")" "$(html_escape "$value")"
            else
                printf '<tr><th>%s</th><td>%s</td></tr>\n' "$(html_escape "$label")" "$(html_escape "$value")"
            fi
        fi
    done <<<"$report"
    [[ "$table_open" == true ]] && printf '</tbody></table>\n'
    printf '</body></html>\n'
} > "$html_file"; then
    printf 'Could not write HTML report to %s\n' "$html_file" >&2
    exit 1
fi
printf '\nStyled report saved to %s (13 pt).\n' "$html_file"
