# `task join-up` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in `task join-up` workflow that installs a PXE creator node before its join nodes so they can retrieve the VIP install profile.

**Architecture:** A new focused shell script will orchestrate the two installation batches: node1, then nodes 2 through `node_count`. The root task will retain `task up` unchanged and invoke the new operation between the existing Admin/NFS setup and NFS CSI installation.

**Tech Stack:** Taskfile v3, Bash, libvirt `virsh`, `yq`, curl.

**Spec:** `docs/superpowers/specs/2026-11-05-join-up-design.md`

## Global Constraints

- Keep `task up` unchanged.
- `task join-up` is for fresh PXE node disks; it must not reset disks or delete VMs.
- Use existing `config.yaml` values for domain prefix, `node_count`, VIP, and `node_installed_timeout`.
- Preserve the existing final VIP stabilization, kubeconfig, readiness, password, NFS server, and NFS CSI steps.

## Review Focus

- `node_count: 1` must not attempt to start a non-existent join node; cover this in `test/join-up.sh`.
- The creator must be running and the VIP reachable before node2/node3 start; assert the mocked command order in `test/join-up.sh`.
- Join nodes must all power off before the final all-node start; assert the second batch wait targets only node2 through `node_count`.
- A configured installation timeout must fail with the names of still-running nodes; cover timeout output in `test/join-up.sh`.
- Re-running `task up` must retain its existing parallel first-boot behavior; cover its unchanged task definition with a focused text assertion in `test/join-up.sh`.

---

### Task 1: Sequential PXE installation script and operation task

**Files:**
- Create: `op/nodes/join-up.sh`
- Modify: `op/Taskfile.yml:102-126`
- Create: `test/join-up.sh`

**Interfaces:**
- Consumes: `config.yaml` fields `.provider.domain_prefix`, `.node_count`, `.vip`, and `.node_installed_timeout`; `op/lib.sh` functions `libvirt_start_domain` and `domain_state`.
- Produces: `op:nodes-join-install`, which leaves every enabled node installed and running, with the existing VIP/readiness/kubeconfig/password tasks completed.

- [ ] **Step 1: Write the failing orchestration regression test**

Create `test/join-up.sh` with a temporary config and mocked `virsh`, `curl`, and `yq` commands. Assert this exact event sequence for `node_count: 3`:

```text
start hvst-node1
wait-shutoff hvst-node1
start hvst-node1
wait-vip 10.0.10.100
start hvst-node2
start hvst-node3
wait-shutoff hvst-node2 hvst-node3
start-all
```

Add cases for `node_count: 1` and for a timed-out join batch reporting its running domains. Assert `op/Taskfile.yml` still defines `nodes-first-boot` with its existing all-node `nodes-start` call.

- [ ] **Step 2: Run the new test to verify it fails**

Run: `bash test/join-up.sh`

Expected: FAIL because `op/nodes/join-up.sh` and `op:nodes-join-install` do not exist.

- [ ] **Step 3: Implement `op/nodes/join-up.sh`**

Source `op/lib.sh`, read the existing configuration, and implement a local `wait_for_shutdown` helper that polls only its supplied domain names at the configured timeout. It must:

1. start node1 and wait for node1 to power off after installation;
2. start node1 again and invoke the existing `wait-vip.sh`;
3. start nodes 2 through `node_count` when present and wait for only that batch to power off;
4. invoke the existing all-node start, VIP stabilization, kubeconfig, readiness, and default-password tasks through the Taskfile wrapper rather than duplicating them.

- [ ] **Step 4: Expose `op:nodes-join-install`**

Add an `op/Taskfile.yml` task that calls `./nodes/join-up.sh`, then runs the existing post-install tasks in the same order as `nodes-install`: `nodes-start`, `wait-vip.sh`, `vip-ensure-stable.sh`, `nodes-rke2-env`, `test-cluster-ready`, and `harvester-change-default-password`.

- [ ] **Step 5: Run the regression test and shell checks**

Run:

```bash
bash test/join-up.sh
bash -n op/nodes/join-up.sh
task --list | grep -F 'op:nodes-join-install'
```

Expected: all commands exit 0 and the test reports `join-up test: PASS`.

- [ ] **Step 6: Commit**

```bash
git add op/nodes/join-up.sh op/Taskfile.yml test/join-up.sh
git commit -m "feat: add sequential PXE join install task"
```

### Task 2: Root `join-up` task

**Files:**
- Modify: `Taskfile.yml:143-152`
- Modify: `test/join-up.sh`

**Interfaces:**
- Consumes: `op:nodes-join-install` from Task 1.
- Produces: root `task join-up`, which performs Admin/PXE setup, starts NFS, sequentially installs the configured PXE nodes, and installs NFS CSI.

- [ ] **Step 1: Extend the failing test**

Add assertions that root `Taskfile.yml` defines `join-up` with the same outer sequence as `up`, substituting only `op:nodes-join-install` for `op:nodes-install`:

```text
admin-up → nfs-up → op:nodes-join-install → nfs-csi-up
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash test/join-up.sh`

Expected: FAIL because `join-up` is absent from root `Taskfile.yml`.

- [ ] **Step 3: Add root `join-up`**

Add a root task named `join-up` next to `up`, with `admin-up` as its dependency and commands `nfs-up`, `op:nodes-join-install`, and `nfs-csi-up` in that order. Do not change `up`.

- [ ] **Step 4: Verify task wiring and configuration validity**

Run:

```bash
bash test/join-up.sh
task --list | grep -F 'join-up'
task config-check
git diff --check
```

Expected: all commands exit 0; `join-up` and `op:nodes-join-install` are listed; config validation succeeds.

- [ ] **Step 5: Commit**

```bash
git add Taskfile.yml test/join-up.sh
git commit -m "feat: add join-up workflow"
```

## Self-review

- **Spec coverage:** Task 1 covers sequential creator/join bootstrapping and preserves existing final cluster tasks. Task 2 adds the requested root command and preserves `task up`.
- **Step scan:** Each code step identifies the exact script/task and ordered behavior; each requirement has a corresponding regression assertion.
- **Type consistency:** Bash scripts consume the existing configuration and helper interfaces; both Taskfiles use the `op:nodes-join-install` name.
- **Review focus:** All five listed failure modes are assigned to `test/join-up.sh` assertions.
- **Proportion:** Two independently testable task-wiring units cover the new script and root entry point without refactoring unrelated installation paths.
