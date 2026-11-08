# authentik

## Database backups

The `authentik` CloudNativePG cluster backs up to `s3://cnpg/authentik/` on fastnas through the barman-cloud plugin:

- WAL is archived continuously (`ObjectStore/authentik`)
- A base backup runs daily at 08:00 UTC (`ScheduledBackup/authentik`)
- Retention is 14 days

`cnpg-system/cloudnative-pg/app/prometheusrule.yaml` alerts on failed or stale (>26h) backups and on WAL
archiving failures, and the CloudNativePG Grafana dashboard shows the recovery window per cluster.

Check backup health:

```sh
kubectl get backup -n security
kubectl get objectstore authentik -n security -o jsonpath='{.status.serverRecoveryWindow}'
kubectl get cluster authentik -n security -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].message}'
```

Take a backup on demand:

```sh
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: authentik-manual-$(date +%Y%m%d%H%M)
  namespace: security
spec:
  cluster:
    name: authentik
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
```

## Restore

The bucket path a cluster archives to is `s3://cnpg/<serverName>/`, and `serverName` defaults to the cluster name.
A cluster refuses to archive into a path that already has WAL in it, so **every restore that keeps the
cluster name must archive to a new `serverName`** (`authentik` → `authentik-2` → `authentik-3` …), and
recover from the previous one.

### Test a restore (non-destructive)

This restores into a throwaway cluster. With no `plugins:` block it never writes to the bucket.

```sh
kubectl apply -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: authentik-restore-test
  namespace: security
spec:
  instances: 1
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6-standard-trixie
  bootstrap:
    recovery:
      source: source
      database: authentik
      owner: authentik
  externalClusters:
    - name: source
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: authentik
          serverName: authentik # the serverName currently being archived to
  storage:
    size: 5Gi
    storageClass: ceph-block
EOF

# compare against live
Q="select count(*) from authentik_core_user;"
kubectl exec -n security authentik-1 -c postgres -- psql -U postgres -d authentik -tAc "$Q"
kubectl exec -n security authentik-restore-test-1 -c postgres -- psql -U postgres -d authentik -tAc "$Q"

# clean up (also removes its PVC and secrets)
kubectl delete cluster authentik-restore-test -n security
```

### Restore the live database

1. Stop Flux from recreating the cluster, and stop authentik:

    ```sh
    flux suspend ks authentik -n security
    kubectl scale deploy -n security authentik-server authentik-worker --replicas=0
    ```

2. In `app/cluster.yaml`, replace `bootstrap.initdb` with `bootstrap.recovery`, add `externalClusters`,
   and bump the archive `serverName`. For the first restore:

    ```yaml
    spec:
        bootstrap:
            recovery:
                source: source
                database: authentik
                owner: authentik
                # Optional point-in-time recovery; omit to replay to the latest WAL
                # recoveryTarget:
                #   targetTime: "2026-11-08 03:56:41+00"
        externalClusters:
            - name: source
              plugin:
                  name: barman-cloud.cloudnative-pg.io
                  parameters:
                      barmanObjectName: authentik
                      serverName: authentik # previous serverName
        plugins:
            - name: barman-cloud.cloudnative-pg.io
              isWALArchiver: true
              parameters:
                  barmanObjectName: authentik
                  serverName: authentik-2 # new, empty path
    ```

    Commit and push. `bootstrap` only applies when a cluster is created, so it's fine to leave this in place
    afterwards; it records where the current cluster came from.

3. Delete the cluster. This also deletes its PVC and the `authentik-app` secret, which CNPG regenerates and
   applies to the `authentik` role on recovery.

    ```sh
    kubectl delete cluster authentik -n security
    ```

4. Resume Flux and wait for the cluster to recover (about a minute for a small database):

    ```sh
    flux resume ks authentik -n security
    kubectl get cluster authentik -n security -w   # until "Cluster in healthy state"
    ```

5. Start authentik and confirm archiving to the new path:

    ```sh
    kubectl scale deploy -n security authentik-server authentik-worker --replicas=1
    kubectl get cluster authentik -n security -o jsonpath='{.status.conditions[?(@.type=="ContinuousArchiving")].message}'
    ```

6. Take an on-demand backup (see above). The new `serverName` has no base backup until the next scheduled
   run, and you can't recover from it until one exists.
