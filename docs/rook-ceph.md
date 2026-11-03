# Rook/Ceph RBD

This repository can install a separate Rook/Ceph block-storage backend for the
local three-node Harvester cluster. It does not replace Longhorn and does not
change the default StorageClass.

The installation is pinned to Rook `v1.21.1`, which supports Kubernetes 1.36.
It deploys the Rook operator and Ceph-CSI operator, creates three Ceph monitors,
two managers, and one OSD on each of the three Harvester nodes. The RBD
StorageClass is named `rook-ceph-rbd` and its provisioner is
`rook-ceph.rbd.csi.ceph.com`.

## Important data warning

`task rook-ceph-up` makes Ceph OSDs from `/dev/vdb` on `node1`, `node2`, and
`node3`. Creating an OSD erases that disk. The task refuses to run unless all
three devices are blank, unpartitioned, unmounted, and have no detected disk
signatures.

Do not change the Rook configuration to use `/dev/vda`. It contains Harvester
and the Longhorn default disk. The three virtual `/dev/vdb` disks are 200 GiB
each. The replicated RBD pool has a replica size of three, so its usable data
capacity is roughly 200 GiB, not 600 GiB.

All three VM disks are backed by the same physical development host. Ceph can
survive the loss of one Harvester VM or one virtual disk, but not the loss of
the host or its libvirt storage. Treat this as development/test storage rather
than production high availability.

## Install

First inspect the disks. This command is read-only:

```bash
task rook-ceph-preflight
```

If it reports that every `/dev/vdb` is blank, install Rook/Ceph:

```bash
task rook-ceph-up
```

The installer applies the version-pinned official manifests for `crds`,
`common`, `csi-operator`, and `operator`, then applies the local
[`cluster.yaml`](../rook/cluster.yaml) and
[`rbd-storageclass.yaml`](../rook/rbd-storageclass.yaml). It waits for the
Ceph cluster, RBD pool, and RBD CSI driver to become ready.

Verify provisioning and a read/write mount with a temporary 1 GiB PVC:

```bash
task rook-ceph-test
```

The test deletes its Pod and PVC when it finishes. `rook-ceph-rbd` is not made
the default StorageClass, so Harvester/Longhorn workloads continue to use
`harvester-longhorn` unless a PVC explicitly selects `rook-ceph-rbd`.

## Use

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: app-data
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: rook-ceph-rbd
  resources:
    requests:
      storage: 10Gi
```

RBD is block storage. Use `ReadWriteOnce` (or `ReadWriteOncePod`) for this
StorageClass. For shared `ReadWriteMany` filesystem storage, use NFS or create
a CephFS-backed StorageClass instead.

## Inspect

```bash
kubectl -n rook-ceph get cephcluster,cephblockpool,pods
kubectl get storageclass rook-ceph-rbd
kubectl get csidriver rook-ceph.rbd.csi.ceph.com
```
