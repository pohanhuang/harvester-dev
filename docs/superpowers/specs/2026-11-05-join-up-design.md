# `task join-up` design

## Intent

Bootstrap a new multi-node PXE Harvester cluster when join installers require the creator node's VIP install-profile endpoint to be available before they can install.

## Goals

- Add a root `task join-up` task for the existing PXE node definitions.
- Start node1 first, wait for its installation to power off, then boot it from disk and wait for the VIP.
- Start node2 through `node_count` only after the VIP is reachable, wait for their installation power-off, then start all nodes and run the existing readiness, kubeconfig, password, NFS, and NFS CSI steps.
- Keep `task up` unchanged.

## Non-goals

- No changes to `iso_boot`, image backend selection, Longhorn disk selection, Terraform resources, or existing node data.
- No automatic disk reset or VM cleanup.

## Approach

Add a focused node-install orchestration script under `op/nodes/` and expose it through an `op:` task. Add root `join-up`, structured like `up`, which runs `admin-up`, `nfs-up`, the new sequential node install task, and `nfs-csi-up`.

The script will read the existing `config.yaml` prefix and `node_count`, use the established libvirt helpers, and preserve the existing final readiness/configuration tasks.

## Constraints

`join-up` is for a fresh PXE installation. Failed or previously installed node disks must be reset by the user first; the task will not erase data automatically.
