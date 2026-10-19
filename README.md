# multipleRCAs — containerized UI + multiple RCA instances

Runs Flexiv Elements Studio (`ui`) and several RobotControlApp simulator instances
(`rca1`, `rca2`, ...) as separate containers on one host.

## Files

| File | Purpose |
| --- | --- |
| `Containerfile` | Builds `flexivapps:v1.0` from `packages/*.zip` (UI + RCA-Sim). |
| `compose.yaml` | Sample: UI + two RCAs sharing one bridge network. |
| `compose.wslg.yaml` | Windows/WSLg variant for the same image and services in a Podman machine. |
| `rca-entrypoint.sh` | RCA container entrypoint (`/opt/flexiv/start-rca`). |
| `uiapp-entrypoint.sh` | UI container entrypoint (`/opt/flexiv/start-flexiv-element`). |
| `start.sh` | Dev helper to run a single podman container interactively. |

## Running

The RCAs must sit on the same L2 network as the UI, and that network must allow
multicast — the RCA enumerates interfaces via `getifaddrs()` requiring
`IFF_UP|IFF_RUNNING|IFF_MULTICAST` (`FvrCommUtilities.cpp`), and the UI discovers
robots over zenoh/DDS multicast. Two supported ways:

**docker compose (rootful daemon):**

```sh
podman save flexivapps:v1.0 | docker load    # image lives in the podman store
docker compose up
```

**rootful podman:**

```sh
sudo podman-compose up
```

Rootless podman does **not** work here: it cannot set up the custom bridge
network (CNI plugin fails), and its default slirp network gives every container
its own isolated `tap0` without the multicast flag. Symptom: the RCA logs
`network not ready, dds publish msg would fail` and never appears in the UI.

`start.sh` is only a single-container dev helper and uses the default podman
network, so it cannot reach other containers.

### Windows with WSLg and Podman

Use `compose.wslg.yaml` as a standalone file instead of `compose.yaml`. It runs
the same UI and two RCAs on the same `10.20.30.0/24` bridge. Stop the other variant
before switching: the container names and network subnet are shared.

Requirements: a running WSL-backed `podman-machine-default`, a rootful Podman
connection, an installed Compose provider, and the image loaded into that
connection's image store. Rootful and rootless Podman use separate image stores.

From PowerShell in this directory, first check the machine's display socket and
FUSE device:

```powershell
podman machine ssh podman-machine-default test -S /mnt/wslg/.X11-unix/X0
podman machine ssh podman-machine-default test -c /dev/fuse
podman info --format '{{.Host.Security.Rootless}}'
```

Both `test` commands must exit successfully; the last command should print
`false`. If the image is not already loaded, run
`podman load -i ..\flexivapps.tar` using that rootful connection. Then validate
and start:

```powershell
podman compose -f .\compose.wslg.yaml config
podman compose -f .\compose.wslg.yaml up
```

The variant mounts `/mnt/wslg/.X11-unix` from the Podman machine at
`/tmp/.X11-unix` inside each container and selects Qt's X11 (`xcb`) platform.
It defaults to `DISPLAY=:0` and needs no Windows `DISPLAY` or `XAUTHORITY`
variable and no Xauthority file. For another WSLg display, set
`$env:WSLG_DISPLAY = ':1'` and check that the corresponding socket (`X1`) exists.
The socket directory must already exist; the mount must not create an empty
replacement directory.

SELinux separation is disabled for these containers so they can use the WSLg
system socket without relabeling it. Do not add `:z` or `:Z` to this mount. The
containers retain their separate IPC namespaces and private `/tmp` directories.
The UI service also adds `NET_RAW` for its ping-based robot address checks;
Podman's default capability set omits it. See the
[upstream defaults](https://github.com/containers/common/blob/main/pkg/config/default.go).

The Compose file creates the bridge and assigns container IPs. Windows routing
and forwarding to that subnet still need separate host configuration. Windows
GUI startup, FUSE operation, accelerated rendering, and Windows-to-container
reachability must be verified on the target machine; local Compose validation
does not establish those runtime results.

## Instance identity

* `RCA_ID` → serial number `AX01L-06-D1-<RCA_ID>`; keep it unique per instance.
  The UI lists robots by serial number, and DDS topic names are SN-suffixed, so
  duplicated SNs corrupt each other's data.
* `-x CX03-02-P1-00034` is the same fake control-box SN for every instance — fine
  for simulation.

## Container environment variables

| Variable | Default | Effect |
| --- | --- | --- |
| `RCA_ID` | `Docker` | Last part of the arm serial number. |
| `RCA_GUI_DISABLE` | `0` | `1` runs with `-g` (no Qt window, no `DISPLAY`/X11 needed). |
| `RCA_SKIP_SETUP` | `0` | `1` skips `setup_RCA.sh` (its only real work is an `apt install`). |

## Things to keep in mind

* **No shared memory between instances.** Everything under `/dev/shm`
  (`shm_USBRelay*`, `shm_HWEcc*`, 20x `shm_flexiv_wib*_WIBSerial*`,
  `sem.mutex_*`, middleware triple buffers) uses fixed names and
  `open_or_create`. Do **not** add `ipc: host` or mount `/dev/shm` into more than
  one RCA container, or a second instance silently attaches to the first one's
  state and the UI's cleanup (`/dev/shm/*flexiv*`) can wipe it.
* **CPU pinning is host-global.** The scheduler pins controller/scheduler threads
  to host CPUs 2/3/4 and comm/planner to 3/4 (`SchedConfig.hpp`); every instance
  uses the same cores. Use a disjoint `cpuset` per service. `SCHED_FIFO` is
  denied inside the container (no `CAP_SYS_NICE`) and the app only logs
  `sched_setscheduler failed` — harmless, add `cap_add: SYS_NICE` if you want it.
* **Do not use the UI's simulator start/stop controls** with externally started
  RCAs. `SystemProcessManagement` spawns and supervises RCA/simulation as child
  processes and checks them with `pgrep`/`netstat`, none of which can see other
  containers; the UI image also ships its own `RobotControlApp` copy.
  Treat the UI as a client and connect to the containerized RCAs over the bridge.
* **One `/tmp` per container.** Sim-dyn arm driver params are written to
  `<parent of -u>/<arm SN>/arm_driver_param` (`/tmp/AX01L-06-D1-<RCA_ID>/...`),
  which is private per container. Sharing `/tmp` would make the instances fight
  over `/tmp/pipeline.*` sockets and `/tmp/RlsServer.pid`.
* **Feature ID is identical in all containers.** The MAC lookup shells out to
  `iwconfig`, which is not installed in the image, so
  `FvrLicenseBase::generateFeatureId()` hashes an empty MAC. Harmless while
  `FVR_ENABLE_LICENSE=OFF`; matters if licensing is enabled.

## Troubleshooting

### WSLg UI cannot discover the RCAs

`/usr/bin/ping: Operation not permitted` is a local permission error, not evidence
that the destination IP is unreachable. The WSLg variant grants `NET_RAW` to
`ui`; after updating an older configuration, recreate that service to apply the
capability (a container restart alone does not apply it):

```powershell
podman compose -f .\compose.wslg.yaml up -d --force-recreate ui
```

Check each running container's actual network membership and current IP before
testing connectivity:

```powershell
podman inspect UIApp RCA1 RCA2 --format '{{.Name}} {{json .NetworkSettings.Networks}}'
```

All three must list the same bridge network. A prefix such as
`containerize_flexiv_apps_bridge` is normal: Compose normally prefixes the network
with the project name. The Podman Desktop "unused" label alone does not establish
the running containers' network membership. If it conflicts with the container
inspection, verify that Desktop and the CLI are viewing the same machine and
rootful/rootless connection:

```powershell
podman system connection list
podman network inspect containerize_flexiv_apps_bridge
```

Substitute the actual network name if different. Do not delete the network based
only on the Desktop label. Then test both current RCA IPs from the UI container;
these are examples and must match the inspection output:

```powershell
podman exec UIApp ping -n -c 2 -W 2 10.20.30.6
podman exec UIApp ping -n -c 2 -W 2 10.20.30.5
```

Successful ping establishes ICMP reachability, not discovery. If both succeed
but the UI still finds no robots, inspect RCA startup/network logs and multicast
discovery traffic next. Windows-to-container routes are not involved in this
container-to-container test. The capability change was checked with a local Linux
UI-image ping reproduction; discovery on the Windows target remains unverified.

Logs: `/opt/flexiv/RobotControlApp-Sim/log/RobotControlApp_*.log` inside the
container.

| Log line | Meaning |
| --- | --- |
| `sched_setscheduler failed: Operation not permitted` | Expected without `CAP_SYS_NICE`; RT priorities are not applied. |
| `network not ready, dds publish msg would fail` | No multicast-capable interface — wrong network mode (rootless/slirp or host network). The UI will not discover this instance. |
| `BSP version file [/tmp/BSP_version.info] is not found` | Expected in simulation containers. |
