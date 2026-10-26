# Windows / WSL2 network setup and troubleshooting

Use this procedure for **rootful Podman on WSL2 with NAT networking**, with the UI and RCAs on the `10.20.30.0/24` bridge. It enables Windows applications to connect to each container's own IP address.

Run commands in **Windows PowerShell**. Use **Administrator PowerShell** when adding or deleting Windows routes. Keep the variables below in the same PowerShell session. The image and WSLg Compose file must already be available.

## 1. Check the Podman machine and connection

```powershell
$machine = 'podman-machine-default'
podman machine info
podman machine inspect --format 'Rootful={{.Rootful}} UserModeNetworking={{.UserModeNetworking}}' $machine
podman machine ssh $machine wslinfo --networking-mode
podman info --format '{{.Host.Security.Rootless}}'
```

Expected: provider `wsl`, `Rootful=true`, `UserModeNetworking=false`, networking mode `nat`, and the last command prints `false`.

If necessary, configure the machine **before starting the containers**:

```powershell
podman machine stop $machine
podman machine set --rootful=true --user-mode-networking=false $machine
podman machine start $machine
podman system connection default podman-machine-default-root
```

Recheck the results. If WSL reports `mirrored` or another mode, use instructions for that topology; the NAT route below does not apply automatically.

## 2. Check container addresses and network membership

Start the services, then inspect the actual network name and current addresses:

```powershell
podman compose -f .\compose.wslg.yaml up -d
podman network ls
podman inspect UIApp RCA1 RCA2 --format '{{.Name}} state={{.State.Status}} {{json .NetworkSettings.Networks}}'

# Replace this with the actual Compose-prefixed network name from inspection.
$network = 'containerize_flexiv_apps_bridge'
$net = @(podman network inspect $network | ConvertFrom-Json)[0]
$bridge = $net.network_interface
$subnet = '10.20.30.0/24'
$rca = @(podman inspect RCA1 | ConvertFrom-Json)[0]
$rcaIP = $rca.NetworkSettings.Networks.PSObject.Properties[$network].Value.IPAddress
```

All containers must be running on the same network ID, with distinct addresses in `10.20.30.0/24` and gateway `10.20.30.1`. Confirm `$bridge` is the actual Linux bridge interface and `$rcaIP` is populated. Stop and correct network selection if inspection fails. A Desktop “unused” label alone does not establish network membership.

## 3. Check and fix container-to-container connectivity

```powershell
podman exec UIApp ping -n -c 1 -W 2 127.0.0.1
podman exec UIApp ping -n -c 2 -W 2 $rcaIP
podman machine ssh $machine sudo -n ping -n -c 2 -W 2 $rcaIP
```

- **`Operation not permitted`:** the ping command lacks permission. Keep `NET_RAW` in the UI service's `cap_add`, alongside its existing capabilities, and recreate the service:

  ```powershell
  podman compose -f .\compose.wslg.yaml up -d --force-recreate ui
  ```

- **Machine-to-RCA succeeds, UI-to-RCA times out:** inspect bridge IP filtering and the forwarding rules:

  ```powershell
  podman machine ssh $machine sysctl net.bridge.bridge-nf-call-iptables
  podman machine ssh $machine cat /sys/class/net/$bridge/bridge/nf_call_iptables
  podman machine ssh $machine sudo -n nft -a list ruleset
  ```

  If either bridge-filtering value is `1`, bridged IPv4 traffic enters the IP firewall hooks. In the Docker-style ruleset, check whether `ip filter FORWARD` has `policy drop`, jumps to `DOCKER-USER`, and lacks a reachable ACCEPT for this bridge. An ACCEPT in Podman's separate `inet netavark` table does not override that DROP.

  **Only for that ruleset**, add the following exception if an equivalent rule is absent:

  ```powershell
  podman machine ssh $machine sudo -n nft insert rule ip filter DOCKER-USER iifname $bridge oifname $bridge counter accept
  ```

  Repeat UI-to-RCA ping and refresh the UI's RCA list. If `DOCKER-USER` is absent, or another rule drops the packet earlier, inspect that rule path instead of creating Docker chains.

Alternative for trusted bridge traffic: set `net.bridge.bridge-nf-call-iptables=0` and ensure the per-bridge `nf_call_iptables` option is also `0`. This bypasses bridge-to-IPv4-firewall hooks across the shared network namespace; IPv6 and native bridge-family filtering are separate. It does **not** bypass filtering of routed Windows-to-container traffic.

## 4. Check and configure the Windows route

Enable Linux forwarding if it is not already `1`:

```powershell
podman machine ssh $machine sysctl net.ipv4.ip_forward
# Run only if forwarding is disabled:
podman machine ssh $machine sudo -n sysctl -w net.ipv4.ip_forward=1
```

Find the WSL machine's Windows-facing interface and address:

```powershell
podman machine ssh $machine ip -4 route show default
podman machine ssh $machine ip -4 addr show eth0

# Use the interface named by the default route; normally eth0 under WSL NAT.
$uplink = 'eth0'
$wslIP = Read-Host 'Enter the WSL uplink IPv4 address, without the prefix length'
Find-NetRoute -RemoteIPAddress $wslIP
Get-NetIPAddress -AddressFamily IPv4 | Format-Table IPAddress,InterfaceIndex,InterfaceAlias
$windowsIP = Read-Host 'Enter the Windows WSL-adapter IPv4 address selected for this path'
$windowsIfIndex = [int](Read-Host 'Enter that Windows WSL-adapter interface index')
Get-NetRoute -DestinationPrefix $subnet -AddressFamily IPv4 -ErrorAction SilentlyContinue
```

The next hop is **WSL's uplink IP**, not the Windows LAN IP or the container gateway. Confirm Windows reaches it through the WSL virtual adapter. If the uplink is not `eth0`, repeat address inspection for the actual interface and update `$uplink`.

If the container-subnet route is missing, add it in **Administrator PowerShell**, retaining or redefining the variables there:

```powershell
route.exe add 10.20.30.0 mask 255.255.255.0 $wslIP metric 1 if $windowsIfIndex
```

If a route already exists, verify its next hop and interface rather than adding a duplicate. Correct a stale route specifically; leave unrelated routes unchanged.

```powershell
Find-NetRoute -RemoteIPAddress $rcaIP
```

Expected: destination prefix `10.20.30.0/24`, next hop `$wslIP`, and selected source `$windowsIP` on the WSL adapter. The destination used by the application remains the container IP.

## 5. Permit Windows requests and container replies

If the route is correct but Windows cannot reach the containers, inspect the Linux rules:

```powershell
podman machine ssh $machine sudo -n nft -a list ruleset
```

For the `ip filter FORWARD` DROP policy described in step 3, the intra-bridge exception is insufficient. Add the following **only when equivalent rules are absent and `FORWARD` reaches `DOCKER-USER`**:

```powershell
# Windows WSL-adapter address -> container subnet
podman machine ssh $machine sudo -n nft insert rule ip filter DOCKER-USER iifname $uplink oifname $bridge ip saddr $windowsIP ip daddr $subnet counter accept

# Replies from containers -> Windows; only established or related traffic
podman machine ssh $machine sudo -n nft insert rule ip filter DOCKER-USER iifname $bridge oifname $uplink ip saddr $subnet ip daddr $windowsIP ct state 'established,related' counter accept
```

These rules are scoped to the selected Windows address and container subnet. Repeated raw insertions create duplicate rules.

## 6. Verify Windows access and locate any remaining block

```powershell
Test-Connection -ComputerName $wslIP -Count 2 -Quiet
Test-Connection -ComputerName $rcaIP -Count 2 -Quiet
podman machine ssh $machine sudo -n nft -a list chain ip filter DOCKER-USER
```

Expect `True` for echo tests and increasing counters on the matching exceptions. Repeat the container test for each actual RCA/UI address.

- **No request-counter increase:** recheck Windows route/source selection, rule conditions, earlier Linux drops, and Windows/Hyper-V firewall policy.
- **Request counter increases but no replies:** check the container's address, return route through `10.20.30.1`, reply exception, and other Linux filtering rules.
- **Ping succeeds but the application fails:** check its actual listening address, protocol, and port. For a TCP service:

  ```powershell
  $servicePort = [int](Read-Host 'Enter the actual listening RCA TCP port')
  Test-NetConnection -ComputerName $rcaIP -Port $servicePort
  ```

If needed, inspect WSL's effective Hyper-V firewall settings and rules:

```powershell
$wslCreator = '{40E0AC32-46A5-438A-A0B2-2B479E8F2E90}'
Get-NetFirewallHyperVVMSetting -PolicyStore ActiveStore -Name $wslCreator
Get-NetFirewallHyperVRule -PolicyStore ActiveStore -VMCreatorId $wslCreator
```

`DefaultInboundAction=Block` alone does not prove host-to-WSL traffic is blocked: `LoopbackEnabled=True` allows host/WSL traffic without additional Hyper-V rules. If policy is responsible, add an address/port-specific rule appropriate to the service; keep the firewall enabled.

Ping verifies ICMP reachability. Test TCP/UDP application access and automatic multicast discovery separately; ordinary IP routing does not automatically forward discovery multicast between Windows and the container bridge.

## Recheck after restart; remove only changes you added

WSL/container addresses and interface indexes may change. The route above is non-persistent, and firewall/network reloads can remove the inserted exceptions. Reinspect the current topology before reapplying them; configure persistence after the setup is verified.

To undo an inserted firewall rule, list `DOCKER-USER` with `nft -a`, identify the exact rule's current handle, and run:

```powershell
$ruleHandle = [int](Read-Host 'Enter the current handle of the rule you added')
podman machine ssh $machine sudo -n nft delete rule ip filter DOCKER-USER handle $ruleHandle
```

To remove a route you added, use **Administrator PowerShell** with that route's current next hop and interface index:

```powershell
route.exe delete 10.20.30.0 mask 255.255.255.0 $wslIP if $windowsIfIndex
```

## References

- [Podman machine settings](https://docs.podman.io/en/latest/markdown/podman-machine-set.1.html)
- [Forwarding exceptions in DOCKER-USER](https://docs.docker.com/engine/network/firewall-iptables/#allow-forwarding-between-host-interfaces)
- [Windows route command](https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/route_ws2008)
- [Linux bridge filtering](https://docs.kernel.org/networking/bridge.html#netfilter)
- [Hyper-V firewall settings](https://learn.microsoft.com/en-us/windows/security/operating-system-security/network-security/windows-firewall/hyper-v-firewall)
