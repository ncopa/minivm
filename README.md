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
sudo ./minivm.sh socket-vmnet-start
sudo ./minivm.sh start edge
./minivm.sh socket-vmnet-status
```
