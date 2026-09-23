# PC Extract Info

`pc-extract-info.sh` prints a human-readable summary of the current Linux computer, including identity, uptime, CPU, memory, disks, network interfaces, VPN-like interfaces, network speed, and USB devices.

## Run

```bash
./pc-extract-info.sh
```

Or run it with Bash:

```bash
bash pc-extract-info.sh
```

The script does not install software or change system settings. It prints `Not available` when a value cannot be read.

## Requirements

The script requires Bash and reads standard Linux interfaces such as `/proc`, `/sys`, and `ip`. The following utilities improve the report and may be absent on some distributions:

- `lsblk`, `df`, `awk`, `sed`, `paste`, `lsusb`, `ip`
- `ethtool` for negotiated network-interface link speed
- `smartctl` for a basic disk health status and temperature
- `sensors` for CPU temperature when the thermal sysfs interface is unavailable
- `speedtest-cli` or Ookla's `speedtest` for an internet speed test
- `sudo` access without a password for optional `dmidecode` RAM module details and `smartctl` data

Missing utilities or restricted hardware access result in unavailable values. Speed tests may contact an external service and consume network bandwidth.

## Notes on reported values

- Uptime is split into 30-day months because a system uptime has no calendar month boundary.
- The CPU's “Day of Manufacture” field from the requested schema is reported as the CPU vendor/implementer when available; Linux does not generally expose a manufacturing date.
- Memory “Free” means available memory, including reclaimable cache, rather than completely unused memory.
- Disk capacity and usage are for the filesystem mounted at `/`. The disk count and names come from detected block devices.
- Disk health is shown as `100%` only when `smartctl` reports `PASSED`; otherwise it is unavailable. This is a pass/fail indication, not a measured health percentage.
- External disks are detected when `lsblk` identifies USB transport. External capacity and usage are currently reported as unavailable.
- VPN detection is heuristic: it looks for default routes using interface names containing `tun`, `tap`, `wg`, `vpn`, or `ppp`. It can miss VPNs that use other interface names, and the absence of one does not prove that no VPN is in use.
- The speed-test values are internet throughput measurements when a compatible speed-test tool is installed. The NIC maximum is the link rate reported by `ethtool`; neither is a file-transfer benchmark.
- The USB port count and model details are based on connected devices reported by `lsusb`, not a physical count of every available port. USB speed is the speed reported for a root hub by `lsusb -t`.

Field names are normalized for readability (for example, “Cock Rate” is displayed as “Clock Rate”). Values that the operating system does not expose are shown as unavailable rather than guessed.
