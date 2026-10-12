# Virtualization Test Outline

What has been tested on OpenShift Virtualization (CNV), and what passed.

All runs are against `oac-dev-workload0`, namespace `mm-test` (the networking suite defaults to `vm-test`). Guest images are CirrOS (`quay.io/kubevirt/cirros-container-disk-demo`) for networking and Fedora Linux 41 Cloud Edition (`quay.io/containerdisks/fedora:41`) for everything that needs a real disk. VM disks land on `pure-fb-nfsv4` (provisioner `pxd.portworx.com`), which is what CDI picks on its own.

The test scripts run entirely as the logged-in user — no `--as system:admin` anywhere — so what they prove is what a real project user can actually do. The one exception is the migration RBAC grant, which a cluster admin applies once per namespace; see [Finding 2](#finding-2-no-shipped-role-delegates-live-migration).

Detail for every suite, including configuration variables and how each check works, is in [vm-testing/README.md](vm-testing/README.md).

## Test Cases

| Test Case | Description | Category | Completion | Notes | Link |
|-----------|-------------|----------|------------|-------|------|
| OpenShift Virtualization Checks | Validates CNV health: virt/CDI/networking Deployments and DaemonSets, HyperConverged, KubeVirt, CDI, NetworkAddonsConfig and SSP conditions, and that the VirtualMachine, VirtualMachineInstance, and DataVolume APIs are served | Platform Readiness | Done | All checks passed | [component-checks/oc-virt-checks.sh](https://github.com/memalhot/open-science-test-cases/tree/main/component-checks/oc-virt-checks.sh) |
| VM Network Tests | Boots a CirrOS VM on an ephemeral `containerDisk` and verifies pod-network connectivity from inside the guest: egress ICMP, DNS resolution, and HTTP, plus inbound access and file transfer over `virtctl ssh`/`scp` | Virtualization | Done | 6 passed, 0 failed | [vm-testing/test-vm.sh](https://github.com/memalhot/open-science-test-cases/tree/main/vm-testing/test-vm.sh) |
| VM Persistent Storage Tests | Provisions a VM root disk as a PVC through CDI, boots a Fedora guest from it, writes a marker inside the guest, then fully stops and restarts the VM and reads the marker back; also reports guest-agent, RWX and `LiveMigratable` status | Virtualization | Done | 9 passed, 0 failed | [vm-testing/test-vm-storage.sh](https://github.com/memalhot/open-science-test-cases/tree/main/vm-testing/test-vm-storage.sh) |
| VM Live Migration Tests | Boots a VM on an RWX PVC, starts a heartbeat inside the guest, migrates it to another node, and verifies it moved without rebooting: same VMI object, unchanged kernel `boot_id`, disk and data intact, and guest pause within budget | Virtualization | Done | 13 passed, 0 failed. Migrated between nodes in 2s (PreCopy) with 0.189s guest-visible downtime | [vm-testing/test-vm-migration.sh](https://github.com/memalhot/open-science-test-cases/tree/main/vm-testing/test-vm-migration.sh) |
| VM Disk Clone Tests | Asks the same StorageClass to clone a disk five ways — a non-cloning control, a bare CSI clone, a CDI clone with no hints, a forced host-assisted copy, and a forced snapshot clone — to locate which layer cloning breaks at | Virtualization | Done | **Fails on this cluster, by design** — 2 of 5 phases succeeded. Reproduces the broken clone path and confirms the snapshot workaround; see [Finding 1](#finding-1-cloning-is-broken-on-pure-fb-nfsv4) | [vm-issues/test-vm-clone.sh](https://github.com/memalhot/open-science-test-cases/tree/main/vm-issues/test-vm-clone.sh) |

