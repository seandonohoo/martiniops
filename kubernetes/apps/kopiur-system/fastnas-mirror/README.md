# fastnas-mirror

Copies the backup buckets on fastnas's SeaweedFS to slownas, so a dead fastnas doesn't take the backups
with it. Runs nightly at 09:00 UTC, after the 08:00 UTC CNPG base backups.

| What                                | Lives on fastnas      | Copy on slownas (`/volume1/fastnas-backup/`) | Made by                                       |
| ----------------------------------- | --------------------- | -------------------------------------------- | --------------------------------------------- |
| kopiur (kopia) repository, app PVCs | S3 bucket `backups`   | `s3/backups`                                 | this CronJob, 09:00 UTC                       |
| CNPG WAL archive and base backups   | S3 bucket `cnpg`      | `s3/cnpg`                                    | this CronJob, 09:00 UTC                       |
| OpenCloud user files                | NFS share `opencloud` | `restic/opencloud` (restic repository)       | `opencloud-backup` in `selfhosted`, 09:30 UTC |

The buckets are copied with `rclone sync`, so deletions are mirrored too. kopia and barman prune their own
buckets, which is expected, but a bucket emptied by mistake would be emptied here on the next run. History
comes from Btrfs snapshots of the `fastnas-backup` share on slownas (Snapshot Replication, daily, after
10:00 UTC, kept 30 days).

All three use the `kopiur` 1Password item: the S3 keys, and `KOPIA_PASSWORD` for both the kopia and the
restic repositories.

## Run it now

```sh
kubectl create job -n kopiur-system fastnas-mirror-manual --from=cronjob/fastnas-mirror
kubectl logs -n kopiur-system job/fastnas-mirror-manual -f

kubectl create job -n selfhosted opencloud-backup-manual --from=cronjob/opencloud-backup
kubectl logs -n selfhosted job/opencloud-backup-manual -f
```

## Restore

Pick the case that matches what was lost. While fastnas is healthy, restore from fastnas as usual; slownas
is only needed when fastnas's copy is gone or damaged.

| Lost                              | Restore from            | How                                                                         |
| --------------------------------- | ----------------------- | --------------------------------------------------------------------------- |
| One app's PVC                     | kopiur on fastnas       | kopiur (below)                                                              |
| The authentik database            | CNPG backups on fastnas | `security/authentik/README.md`                                              |
| OpenCloud files                   | restic on slownas       | `selfhosted/opencloud/README.md`                                            |
| fastnas itself, or a bucket on it | `s3/` on slownas        | [Rebuild fastnas's buckets](#rebuild-fastnass-buckets), then the rows above |

### One app's PVC (kopiur)

The kopiur component's PVC is populated by its `Restore` when the PVC is created, from the latest snapshot
(the `Restore` pins a snapshot per PVC UID, so a recreated PVC resolves again). To roll an app back:

```sh
flux suspend ks <app> -n <namespace>
kubectl scale deploy <app> -n <namespace> --replicas=0
kubectl delete pvc <app> -n <namespace>
flux resume ks <app> -n <namespace>   # recreates the PVC, populated from the latest snapshot
```

To go back further than the latest snapshot, set `spec.source.fromPolicy.offset` on the app's `Restore`
(1 = the one before latest) before resuming.

### Rebuild fastnas's buckets

1. Bring SeaweedFS's S3 back on fastnas with the same access keys as the `kopiur` 1Password item
   (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`).

2. Copy the buckets back from slownas. This reuses the mirror CronJob with the direction reversed:

    ```sh
    kubectl create job -n kopiur-system fastnas-restore --from=cronjob/fastnas-mirror --dry-run=client -o yaml \
      | yq '.spec.template.spec.containers[0].command = ["/bin/sh", "-c", "set -e; for b in backups cnpg; do rclone mkdir fastnas:$b; rclone sync /backup/s3/$b fastnas:$b --fast-list --transfers 8 --stats-one-line --stats 1m; done"]' \
      | kubectl apply -f -
    kubectl logs -n kopiur-system job/fastnas-restore -f
    ```

    To restore the buckets as they were on an earlier day, use a snapshot path instead of `/backup/s3/$b`:
    `/backup/#snapshot/<snapshot name>/s3/$b`. The `#snapshot` folder only appears over NFS with **Make
    snapshot visible** turned on for the share; otherwise restore the snapshot to a new folder in DSM first.

3. **Before the next 09:00 UTC run**, confirm the buckets are back (`rclone size fastnas:backups`). If the
   mirror runs while fastnas's buckets are still empty, it empties `s3/` on slownas too; the Btrfs
   snapshots still have it, but restoring from them is slower. To be safe, suspend it until then:

    ```sh
    kubectl patch cronjob fastnas-mirror -n kopiur-system -p '{"spec":{"suspend":true}}'
    # once restored; Flux won't undo the patch by itself
    kubectl patch cronjob fastnas-mirror -n kopiur-system -p '{"spec":{"suspend":false}}'
    ```

4. kopiur and CNPG need nothing else; restore PVCs or the database as in the rows above.

5. Rebuild the OpenCloud share (see the fastnas setup in `selfhosted/opencloud/README.md`) and restore its
   files from restic.
