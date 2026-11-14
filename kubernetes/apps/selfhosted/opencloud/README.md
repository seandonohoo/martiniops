# opencloud

OpenCloud at `https://oc.martiniops.com` (internal gateway), signing in through Authentik.

## Storage

| What                                                                                                   | Where                                                       |
| ------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------- |
| User files (`/data`)                                                                                   | NFS `10.26.10.20:/volume1/opencloud` (slownas)              |
| Config (`/etc/opencloud`), IDM, NATS, search index, thumbnails, system metadata (`/var/lib/opencloud`) | `opencloud` PVC on `ceph-block`, backed up hourly by kopiur |

slownas tops out at NFS 4.1, and extended attributes over NFS need 4.2. OpenCloud's default `posix` storage
driver keeps its metadata in xattrs, so this uses the `decomposed` driver, which keeps metadata in
messagepack files next to the blobs. Files on the share are stored by ID, not by name, so they're not
browsable from the NAS. There's no migration path from `decomposed` to `posix` later; switching means
copying the data into a new installation.

The user files aren't covered by kopiur. Back up `/volume1/opencloud` on the NAS (Hyper Backup or
snapshots). Restoring one without the other leaves them out of step: the PVC holds the space metadata
and the NAS holds the blobs.

### slownas setup (before first deploy)

1. In DSM, create the shared folder `opencloud` on volume 1.
2. Add an NFS rule for it: host `10.26.10.0/24`, read/write, squash **No mapping**, security `sys`.
3. Make the folder owned by uid/gid `1000` (the user OpenCloud runs as). Over SSH on the NAS:
   `sudo chown 1000:1000 /volume1/opencloud && sudo chmod 750 /volume1/opencloud`.

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
    - Regex: `http://127\.0\.0\.1(:[0-9]+)?(/.*)?` (desktop)
    - Regex: `http://localhost(:[0-9]+)?(/.*)?` (desktop)
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
