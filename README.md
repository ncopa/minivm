# minivm

Small POSIX shell manager for QEMU VMs on macOS.

## Usage

```sh
./minivm.sh create edge cdrom=$HOME/Downloads/alpine.iso
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
