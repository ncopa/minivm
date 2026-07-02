# minivm

Small POSIX shell manager for QEMU VMs on macOS.

## Usage

```sh
./minivm.sh create edge cdrom=$HOME/Downloads/alpine.iso
./minivm.sh run edge
./minivm.sh ssh edge root
./minivm.sh list
```
