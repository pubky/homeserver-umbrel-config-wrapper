# cloudflared-runtime

A thin, self-built runtime image for the Cloudflare Tunnel used by the Pubky
Homeserver Umbrel app. It exists to collapse the app's THREE cloudflared
compose services (token mode, locally-managed config.yml mode, preview quick
tunnel) into ONE service. Today, whichever two modes are not configured
simply crash-loop forever as a file-gating mechanism, because the official
cloudflared image is distroless and has no shell to make a decision with.

## What it does

`entrypoint.sh` selects the tunnel mode by file fingerprint in
`/etc/cloudflared-config` (overridable via `CLOUDFLARED_CONFIG_DIR`), with
the same precedence the dashboard uses:

1. `config.yml` present: `cloudflared tunnel --no-autoupdate --config
   /etc/cloudflared-config/config.yml run` (connected-account mode)
2. `token` present and non-empty: `cloudflared tunnel --no-autoupdate run`
   with `TUNNEL_TOKEN_FILE=/etc/cloudflared-config/token` exported, the same
   native file-reading mechanism the compose service uses today
3. `testdrive.env` present: sources it (it carries `TUNNEL_URL=...`) and
   runs `cloudflared tunnel --no-autoupdate --logfile
   /etc/cloudflared-config/preview/quick.log`, identical to the current
   preview service (URL via env, quick-tunnel URL discovered through the
   logfile by the config wrapper and the dashboard)
4. none of the above: log one waiting line and re-check every 10 seconds.
   No crash-looping.

The selected mode and full argv are logged on one line before `exec`. Since
`exec` replaces the shell, a mode change after startup still requires a
container restart, exactly like the three-service setup it replaces.

## Supply-chain consideration (why this is decision-gated)

The cloudflared binary is `COPY --from` the official image at the exact
digest the app store's `docker-compose.yml` pins today
(`cloudflare/cloudflared:2026.5.2@sha256:12ff5c6992a9863db4da270746af7c244bcaee49353039af8104268a18d6c4f0`),
and the alpine base is also pinned by digest. So the bits of cloudflared
that run are unchanged; what changes is that they now run inside an image we
build and publish instead of Cloudflare's image untouched. That is a real
supply-chain stance change (our build pipeline and registry account become
part of the trust chain for the tunnel binary) and needs an explicit team
OK before adoption.

Adopting it also requires the compose change in the app store repo that
replaces the three services with one (kept on a separate decision-gated
branch there).

## Build and test

```sh
docker build -t synonymsoft/cloudflared-runtime:dev cloudflared-runtime/
sh cloudflared-runtime/test.sh   # host-side mode-selection tests, no docker
```
