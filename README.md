# fly-volume-publish

Publish versioned build files (APKs, zips, installers) to a [Fly.io](https://fly.io) volume that
nginx serves, from GitHub Actions or from your own machine.

Every publish, on the machine and under a lock:

1. The upload goes to `<files dir>/.incoming/` and is **renamed** into place, so nobody can download
   a half-written file.
2. A `<file>.sha256` is written next to it.
3. `<product>-latest<suffix>` (a relative symlink) moves to the new version, unless a newer version
   is already there (rebuilding an old version never moves `latest` backwards).
4. Only the newest `keep` versions (default 3) of each product are kept. The version `latest` points
   to is never removed.
5. `manifest.json` is rewritten, so a download page can list the builds without being redeployed.
6. The public URL is asked for the file (and the `latest` link), and the run fails if the size does
   not match.

Files are named `<product>-<version><suffix>`: `product` is lowercase letters, digits and dashes,
`version` is `x.y.z`, `suffix` starts with `.` or `-` (`.apk`, `-win-x64.zip`). So
`myapp-1.2.0.apk` is product `myapp`, suffix `.apk`, and `myapp-host-1.2.0-win-x64.zip` is product
`myapp-host`, suffix `-win-x64.zip`.

## What you need

- A Fly app with **one machine** and a volume (mounted at `/srv/files` by default) and nginx serving
  that directory, e.g. `location /files/ { alias /srv/files/; }`.
- A public path that always answers 200 (default `/health`). It wakes a machine that stopped when
  idle: `fly ssh` does **not** start a stopped machine, an HTTP request through the Fly proxy does.
- Keep dot-files on the volume private (`.incoming`, `.lock`), e.g.
  `location ~ ^/files/\. { return 404; }`.
- A token that can only ssh into that app:

  ```bash
  fly tokens create ssh -a <app> -x 8760h
  ```

  Note that Fly's ssh tokens may also connect to the organization's WireGuard network. Treat the
  token as sensitive and give it a short expiry.

## Use in a workflow

```yaml
on:
  push:
    branches: [main]            # never pull_request: the token must not reach PR builds

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      # ... build the file ...
      - uses: talgrim/fly-volume-publish@v1
        with:
          file: artifacts/myapp.apk
          product: myapp
          version: 1.2.0
          suffix: .apk
          fly-app: my-files
          base-url: https://files.example.com
          fly-api-token: ${{ secrets.FLY_API_TOKEN }}
```

Optional inputs: `files-dir` (`/srv/files`), `url-path` (`/files`), `health-path` (`/health`),
`keep` (`3`). Pin the action to a commit SHA if you want it immutable.

## Use from a shell

```bash
export FLY_APP=my-files PUBLISH_URL=https://files.example.com   # flyctl logged in, or FLY_API_TOKEN set
./scripts/publish.sh app-release.apk myapp 1.2.0 .apk
./scripts/publish.sh --reindex     # rebuild manifest.json and checksums from what is on the volume
```

## manifest.json

```json
{"generated":"2026-11-19T18:50:03Z","files":[
  {"product":"myapp","version":"1.2.0","suffix":".apk","file":"myapp-1.2.0.apk",
   "size":3457817,"updated":"2026-11-19","sha256":"…","latest":true}
]}
```

Newest version first within a product and suffix. A download page can fetch it and link to
`<product>-latest<suffix>` for the newest build. Serve it with `Cache-Control: no-cache`.

## Tests

```bash
./scripts/test-remote-publish.sh               # in an alpine container (or the host shell if there is no Docker)
FLY_APP=... PUBLISH_URL=... ./scripts/test-remote-publish.sh --on-machine   # on the real machine, in /tmp
```

CI runs the first form and ShellCheck on every pull request. Nothing there uses a Fly token.

## License

MIT
