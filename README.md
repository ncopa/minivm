# minivm

Small POSIX shell manager for QEMU VMs on macOS.

## Usage

```sh
./minivm.sh create edge cdrom=$HOME/Downloads/alpine.iso
./minivm.sh create alpine image_url=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/generic_alpine-3.24.1-aarch64-uefi-tiny-r0.qcow2 disk_size=32G
./minivm.sh create tiny image_url=https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/cloud/generic_alpine-3.24.1-aarch64-uefi-tiny-r0.qcow2 ssh_authorized_keys=$HOME/.ssh/id_ed25519.pub
./minivm.sh run edge
./minivm.sh ssh edge root
./minivm.sh list
```

For `net=socket_vmnet`, `minivm.sh` can manage a shared `socket_vmnet` daemon:

```sh
sudo ./minivm.sh socket-vmnet-start --gateway=192.168.105.1
sudo ./minivm.sh start edge
./minivm.sh socket-vmnet-status
```

The shared daemon can be configured with environment variables such as:

```sh
SOCKET_VMNET_MODE_DEFAULT=shared
SOCKET_VMNET_GATEWAY_DEFAULT=192.168.105.1
SOCKET_VMNET_DHCP_END_DEFAULT=192.168.105.254
SOCKET_VMNET_MASK_DEFAULT=255.255.255.0
```
