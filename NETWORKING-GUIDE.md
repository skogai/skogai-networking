# SkogAI Networking — Service Onboarding Guide

Procedure for wiring a new service into the current setup: Podman quadlets under
`~/.config/containers/systemd/`, one Cloudflare tunnel (`skogai`) carrying HTTP
ingress, and per-service networks bridged only where a name lookup is actually
needed. This is the checklist, not a code dump — see the running services for
worked examples of each step.

## 0. Pick the right remote-access mechanism first

Four mechanisms exist on this host today. Decide which one before writing anything:

| Need | Use |
|---|---|
| A hostname the public internet can hit, backed by a container | Cloudflare Tunnel `skogai` (HTTP ingress) |
| Reach a private IP/subnet from an enrolled device, no public hostname | Cloudflare Tunnel `skognet` (WARP routing) |
| Reach the workstation itself from another enrolled device | Cloudflare Tunnel `skogix-workstation-service` |
| Everything else already covered by Tailscale or Pangolin/`newt` | Confirm it's not already handled there before adding a third path |

Never reuse a name across a Podman network, a Cloudflare tunnel, an IP route,
and a DNS record. Same name across those does not imply any connection —
each one is a separate object that has to be wired up explicitly.

## 1. Create the service's own directory

```
~/.config/containers/systemd/<service>/
```

One directory per service. Sidecars that belong only to that service
(its own Postgres, etc.) live in the same directory.

## 2. Give it its own network, isolated by default

```
<service>/<service>.network
```

```ini
[Network]
NetworkName=<service>
```

Nothing else is attached to this network unless step 4 says so.

## 3. Write the `.container` file(s)

- `ContainerName=` matches the ID other configs will reference it by.
- `EnvironmentFile=` as a path relative to this directory (or `%h/...`
  absolute) — a stale absolute path left over from moving files is a
  silent failure, not a loud one.
- `Restart=always`, `RestartSec=5` unless there's a reason not to.
- Sidecars (Postgres, etc.) declare `Network=<service>` only — never give a
  database a second network leg.

## 4. Bridge networks only where a name lookup is actually needed

Rule: the **caller** gets a second `Network=` line pointing at the
**callee's** network. The callee's quadlet is never touched.

```ini
[Container]
Network=<service>-own-network
Network=<other-service>.network
```

Example already in place: `skogai-mcphub` has three `Network=` lines —
its own Postgres network, `skogai-tunnel.network` (so the tunnel connector
can reach it by name), and `basic-memory.network` (so it can reach
`basic-memory` by name).

## 5. Apply and verify

```bash
systemctl --user daemon-reload
systemctl --user restart <service>.service
```

Confirm network membership directly — don't trust `systemctl status` alone:

```bash
podman network inspect <network> --format \
  '{{range .Containers}}{{.Name}} {{range .Interfaces}}{{range .Subnets}}{{.IPNet}}{{end}}{{end}}{{"\n"}}{{end}}'
```

A `.network` quadlet showing `active (exited)` only means the create command
succeeded once — it does not confirm the Podman network still exists right
now. Check with the command above, not `systemctl --user status`.

## 6. If it needs to be reachable from outside (tunnel ingress)

1. Put the service on `skogai-tunnel.network` (step 4).
2. Add an ingress rule on tunnel `skogai` mapping a hostname to
   `http://<container-name>:<port>`.
3. `cloudflared tunnel route dns skogai <hostname>` if the DNS record
   doesn't exist yet.
4. Confirm with `cloudflared tunnel info skogai` that a connector is
   actually attached — a tunnel with zero connections will 502 no matter
   how correct the ingress rule is.

## 7. Run the tests

See the "tests" work item (tracked as a GitHub issue) — the goal is a
one-command check that every declared endpoint resolves and every
service is actually up, so a broken bridge shows up immediately instead
of during the next unrelated debugging session.

## Known drift traps (found the hard way — check these first when something silently breaks)

1. A `.container` file's `Network=` lines don't match what's actually
   attached in Podman — verify with the `podman network inspect` command
   in step 5, not by reading the quadlet file.
2. `EnvironmentFile=` pointing at a path that was valid before a
   directory reorganization.
3. A service reference (MCPHub group, tunnel ingress rule, etc.) naming
   a server/container that doesn't exist — these fail with a plain
   "not found," not a networking error, so they're easy to misdiagnose
   as connectivity problems.
