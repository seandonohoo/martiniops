# opencloud

OpenCloud at `https://oc.martiniops.com` (internal gateway), signing in through Authentik.

## Storage

| What                                                                                                   | Where                                                       |
| ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| User files (`/data`)                                                                                   | NFS 4.2 `10.26.10.15:/opencloud` (fastnas, RAID10 NVMe)     |
| Config (`/etc/opencloud`), IDM, NATS, search index, thumbnails, system metadata (`/var/lib/opencloud`) | `opencloud` PVC on `ceph-block`, backed up hourly by kopiur |

This uses OpenCloud's default `posix` storage driver, which keeps files under their real names
(`users/<username>/…`, `projects/<space id>/…`) and stores its metadata in extended attributes on them.
NFS only carries xattrs from 4.2, so `/data` is a static PV (`persistentvolume.yaml`) that pins
`nfsvers=4.2`; an inline `nfs` volume can't set mount options. Usernames are Authentik's hashed `sub`
(see below), so personal folders are named by that hash.

The user files aren't covered by kopiur (NFS volumes have no CSI snapshots). The `opencloud-backup` CronJob
backs them up with restic every night at 09:30 UTC to `slownas:/volume1/fastnas-backup/restic/opencloud`,
keeping 7 daily, 4 weekly and 6 monthly snapshots. restic stores the xattrs, so slownas only needs NFS 4.1.
Any other copy has to keep them too (`rsync -aX`): without them OpenCloud loses track of the files.
The repository password is `KOPIA_PASSWORD` from the `kopiur` 1Password item; changing it there locks you
out of this repository until you `restic key add` the new one.

Restoring one side without the other leaves them out of step: the PVC holds the space and share metadata,
and the NAS holds the files. Restore both to roughly the same time.

### Restore the user files

To check a backup without touching anything, restore into the job's scratch space, and list the xattrs
restic stored for the personal spaces (names only; the values are base64):

```sh
kubectl create job -n selfhosted opencloud-restore-test --from=cronjob/opencloud-backup --dry-run=client -o yaml \
  | yq '.spec.template.spec.containers[0].command = ["/bin/sh", "-c", "set -e; restic snapshots; restic restore latest --target /tmp/restore; find /tmp/restore -type f | head; restic cat tree latest:/data/users | grep -o \"\\\"name\\\":\\\"user[^\\\"]*\\\"\" | sort | uniq -c"]' \
  | kubectl apply -f -
kubectl logs -n selfhosted job/opencloud-restore-test -f
kubectl delete job -n selfhosted opencloud-restore-test
```

For a real restore (this overwrites `/data` on fastnas):

```sh
flux suspend hr opencloud -n selfhosted
kubectl scale deploy opencloud -n selfhosted --replicas=0
kubectl create job -n selfhosted opencloud-restore --from=cronjob/opencloud-backup --dry-run=client -o yaml \
  | yq '.spec.template.spec.containers[0].command = ["/bin/sh", "-c", "restic snapshots && restic restore latest --target / --include /data"]
      | (.spec.template.spec.containers[0].volumeMounts[] | select(.mountPath == "/data")).readOnly = false' \
  | kubectl apply -f -
kubectl logs -n selfhosted job/opencloud-restore -f
```

Use a snapshot ID instead of `latest` to go further back. Then restore the `opencloud` PVC from kopiur to a
matching time, and resume the HelmRelease.

### fastnas setup (before first deploy)

1. In OMV, **Storage → Shared Folders → Create**: name `opencloud`, on the RAID10 file system.
2. Over SSH on fastnas, make it owned by uid/gid `1000` (the user OpenCloud runs as). The pod's `fsGroup`
   isn't applied to NFS volumes. The Shared Folders list shows the absolute path:

    ```sh
    sudo chown 1000:1000 /srv/dev-disk-by-uuid-<…>/opencloud
    sudo chmod 750 /srv/dev-disk-by-uuid-<…>/opencloud
    ```

3. **Services → NFS → Settings**: enabled, with version 4.2 among the allowed versions.
4. **Services → NFS → Shares → Create**: shared folder `opencloud`, client `10.26.10.0/24`, permission
   read/write, extra options `no_subtree_check,insecure`. Save and apply.
5. Check it took effect:

    ```sh
    cat /proc/fs/nfsd/versions   # includes +4.2
    sudo exportfs -v             # /export/opencloud for 10.26.10.0/24, rw
    ```

    OMV exports `/export` as the NFSv4 root (`fsid=0`), so clients mount `/opencloud`, not
    `/export/opencloud`.

## Authentik setup (before first deploy)

Create one OAuth2/OpenID provider and an application with slug `opencloud`. Desktop and mobile clients
use the same provider: Authentik gives each provider its own issuer, and OpenCloud only takes one
issuer, so the webfinger client IDs all point at `web`.

- **Client type:** Public
- **Client ID:** `web`
- **Redirect URIs:**
    - Strict: `https://oc.martiniops.com/`
    - Strict: `https://oc.martiniops.com/oidc-callback.html`
    - Strict: `https://oc.martiniops.com/oidc-silent-redirect.html`
    - Regex: `http://127\.0\.0\.1(:\d+)?(/.*)?` (desktop)
    - Regex: `http://localhost(:\d+)?(/.*)?` (desktop)
    - Use `\d`, not `[0-9]`: Authentik (2026.8) runs every redirect URI through `urlparse` to build the
      discovery endpoint's CORS header, and brackets in the host part raise "Invalid IPv6 URL", so
      discovery returns 500 to the web client.
    - Strict: `oc://android.opencloud.eu`
    - Strict: `oc://ios.opencloud.eu`
- **Signing key:** pick a certificate (e.g. the self-signed one). OpenCloud verifies access tokens as
  RS256 JWTs; without a key Authentik signs with HS256 and OpenCloud rejects them ("invalid kid").
- **Scopes:** `openid`, `profile`, `email`, `offline_access`. `profile` carries the `groups` claim.
- **Subject mode:** leave the default (hashed user ID). OpenCloud keys users on `sub`, so changing it
  later orphans everyone's account.
- **Logout:** back-channel, URI `https://oc.martiniops.com/backchannel_logout`.

Create the groups OpenCloud maps to roles and add users to them. A user in none of them can't sign in.

| Authentik group       | OpenCloud role |
| --------------------- | -------------- |
| `opencloudAdmin`      | Admin          |
| `opencloudSpaceAdmin` | Space Admin    |
| `opencloudUser`       | User           |
| `opencloudGuest`      | User Light     |

Accounts are created in OpenCloud on first sign-in, and roles are re-applied from the groups on every
sign-in.
