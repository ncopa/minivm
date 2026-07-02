#!/bin/sh

set -eu

PROG=${0##*/}
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
INSTANCES_DIR=${MINIVM_INSTANCES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/minivm/instances}
QEMU_BIN=${QEMU_BIN:-qemu-system-aarch64}
QEMU_IMG_BIN=${QEMU_IMG_BIN:-qemu-img}
EFI_DEFAULT=${EFI_DEFAULT:-/opt/homebrew/share/qemu/edk2-aarch64-code.fd}
ACCEL_DEFAULT=${ACCEL_DEFAULT:-hvf}
MACHINE_DEFAULT=${MACHINE_DEFAULT:-virt}
MEMORY_DEFAULT=${MEMORY_DEFAULT:-8G}
DISK_SIZE_DEFAULT=${DISK_SIZE_DEFAULT:-64G}
DISK_FORMAT_DEFAULT=${DISK_FORMAT_DEFAULT:-qcow2}
SSH_PORT_BASE=${SSH_PORT_BASE:-22000}
SOCKET_VMNET_CLIENT_BIN=${SOCKET_VMNET_CLIENT_BIN:-}

usage() {
	cat <<EOF
Usage:
  $PROG create NAME [key=value ...]
  $PROG run NAME [-- qemu-args...]
  $PROG start NAME [-- qemu-args...]
  $PROG stop NAME
  $PROG ssh NAME [ssh-opts...] [-- remote-cmd...]
  $PROG list
  $PROG show NAME
  $PROG delete NAME

Config keys:
  disk, disk_size, disk_format, cdrom, memory, cpus, ssh_port, ssh_key, macaddr
  net_iface, net_iface_mac, socket_vmnet_path, socket_vmnet_mode
  qemu, qemu_img, efi, accel, machine, net, headless, boot, extra_args

Notes:
  - macOS/Apple Silicon defaults are tuned for aarch64 guests with hvf.
  - 'run' stays in the foreground. 'start' daemonizes and writes a pid file.
  - Prefer net_iface_mac for removable USB NICs with net=vmnet-bridged.
  - socket_vmnet requires an already-running socket_vmnet daemon.
EOF
}

die() {
	printf '%s: %s\n' "$PROG" "$*" >&2
	exit 1
}

have() {
	command -v "$1" >/dev/null 2>&1
}

default_cpus() {
	if have sysctl; then
		n=$(sysctl -n hw.perflevel0.physicalcpu 2>/dev/null || true)
		if [ -n "${n:-}" ]; then
			printf '%s\n' "$n"
			return
		fi
		n=$(sysctl -n hw.physicalcpu 2>/dev/null || true)
		if [ -n "${n:-}" ]; then
			printf '%s\n' "$n"
			return
		fi
	fi
	printf '%s\n' 4
}

default_mac() {
	name=$1
	set -- $(printf '%s' "$name" | cksum)
	sum=$1
	printf '52:54:%02x:%02x:%02x:%02x\n' \
		$(( (sum >> 24) & 255 )) \
		$(( (sum >> 16) & 255 )) \
		$(( (sum >> 8) & 255 )) \
		$(( sum & 255 ))
}

default_ssh_port() {
	name=$1
	set -- $(printf '%s' "$name" | cksum)
	sum=$1
	printf '%s\n' $(( SSH_PORT_BASE + (sum % 1000) ))
}

instance_dir() {
	printf '%s/%s\n' "$INSTANCES_DIR" "$1"
}

config_path() {
	printf '%s/config\n' "$(instance_dir "$1")"
}

require_instance() {
	[ -f "$(config_path "$1")" ] || die "instance '$1' does not exist"
}

ensure_dirs() {
	mkdir -p "$INSTANCES_DIR"
}

write_config() {
	name=$1
	dir=$(instance_dir "$name")
	cfg=$dir/config
	shift

	mkdir -p "$dir"
	: > "$cfg"
	for kv do
		key=${kv%%=*}
		value=${kv#*=}
		printf '%s=%s\n' "$key" "$(quote_sh "$value")" >> "$cfg"
	done
}

quote_sh() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

default_socket_vmnet_client() {
	if [ -n "$SOCKET_VMNET_CLIENT_BIN" ]; then
		printf '%s\n' "$SOCKET_VMNET_CLIENT_BIN"
		return
	fi
	for bin in \
		/opt/homebrew/opt/socket_vmnet/bin/socket_vmnet_client \
		/usr/local/opt/socket_vmnet/bin/socket_vmnet_client
	do
		if [ -x "$bin" ]; then
			printf '%s\n' "$bin"
			return
		fi
	done
	printf '%s\n' socket_vmnet_client
}

resolve_socket_vmnet_client() {
	client=$(default_socket_vmnet_client)
	if [ "${client#/}" != "$client" ]; then
		[ -x "$client" ] || die "socket_vmnet_client not found at '$client'"
	else
		have "$client" || die "socket_vmnet_client not found; install socket_vmnet or set SOCKET_VMNET_CLIENT_BIN"
	fi
	printf '%s\n' "$client"
}

resolve_iface_by_mac() {
	want_mac=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	have networksetup || die "networksetup is required to resolve net_iface_mac"
	result=$(
		networksetup -listallhardwareports 2>/dev/null | awk -v want="$want_mac" '
			/^Device: / {
				device = substr($0, 9)
			}
			/^Ethernet Address: / {
				mac = tolower(substr($0, 19))
				if (mac == want) {
					count++
					found_device = device
				}
			}
			END {
				if (count == 1) {
					print found_device
				} else if (count > 1) {
					exit 2
				} else {
					exit 1
				}
			}
		'
	) || rc=$?
	rc=${rc:-0}
	case $rc in
	0)
		printf '%s\n' "$result"
		;;
	1)
		die "net_iface_mac '$1' was not found; check whether the NIC is plugged in"
		;;
	2)
		die "net_iface_mac '$1' matched multiple interfaces"
		;;
	*)
		die "failed to resolve net_iface_mac '$1'"
		;;
	esac
}

load_config() {
	name=$1
	dir=$(instance_dir "$name")
	cfg=$dir/config
	require_instance "$name"
	# shellcheck disable=SC1090
	. "$cfg"

	instance_name=$name
	instance_dir=$dir
	runtime_dir=$dir/run
	log_dir=$dir/log
	pidfile=$runtime_dir/qemu.pid
	qmp_socket=$runtime_dir/qmp.sock
	qga_socket=$runtime_dir/qga.sock

	qemu=${qemu:-$QEMU_BIN}
	qemu_img=${qemu_img:-$QEMU_IMG_BIN}
	efi=${efi:-$EFI_DEFAULT}
	accel=${accel:-$ACCEL_DEFAULT}
	machine=${machine:-$MACHINE_DEFAULT}
	memory=${memory:-$MEMORY_DEFAULT}
	cpus=${cpus:-$(default_cpus)}
	disk_format=${disk_format:-$DISK_FORMAT_DEFAULT}
	disk=${disk:-$instance_dir/disk.$disk_format}
	ssh_port=${ssh_port:-$(default_ssh_port "$name")}
	ssh_key=${ssh_key:-}
	macaddr=${macaddr:-$(default_mac "$name")}
	net=${net:-user}
	net_iface=${net_iface:-}
	net_iface_mac=${net_iface_mac:-}
	socket_vmnet_path=${socket_vmnet_path:-}
	socket_vmnet_mode=${socket_vmnet_mode:-shared}
	headless=${headless:-yes}
	boot=${boot:-menu=on,splash-time=0}
	extra_args=${extra_args:-}
}

assemble_qemu() {
	load_config "$1"
	shift

	mkdir -p "$runtime_dir" "$log_dir"
	rm -f "$qmp_socket" "$qga_socket"

	if [ "${1:-}" = "--" ]; then
		shift
	fi

	set -- "$qemu" \
		-accel "$accel" \
		-machine "$machine" \
		-cpu host \
		-smp "$cpus" \
		-m "$memory" \
		-boot "$boot" \
		-pidfile "$pidfile" \
		-chardev "socket,id=qmp,path=$qmp_socket,server=on,wait=off" \
		-qmp "chardev:qmp" \
		-device virtio-rng-pci \
		-rtc base=utc,clock=host \
		-parallel none

	if [ -n "$efi" ]; then
		set -- "$@" -bios "$efi"
	fi

	if [ -n "${disk:-}" ]; then
		set -- "$@" -drive "if=virtio,format=$disk_format,file=$disk"
	fi

	if [ -n "${cdrom:-}" ]; then
		set -- "$@" -drive "if=none,media=cdrom,id=cdrom0,file=$cdrom" -device usb-storage,drive=cdrom0
	fi

	case $net in
	user)
		set -- "$@" \
			-netdev "user,id=net0,hostfwd=tcp:127.0.0.1:$ssh_port-:22" \
			-device "virtio-net-pci,netdev=net0,mac=$macaddr"
		;;
	vmnet-shared|vmnet-host)
		set -- "$@" \
			-netdev "$net,id=net0" \
			-device "virtio-net-pci,netdev=net0,mac=$macaddr"
		;;
	vmnet-bridged)
		netdev="$net,id=net0"
		if [ -n "$net_iface_mac" ]; then
			netdev_iface=$(resolve_iface_by_mac "$net_iface_mac")
		elif [ -n "$net_iface" ]; then
			netdev_iface=$net_iface
		else
			die "net=vmnet-bridged requires net_iface_mac or net_iface"
		fi
		netdev="$netdev,ifname=$netdev_iface"
		set -- "$@" \
			-netdev "$netdev" \
			-device "virtio-net-pci,netdev=net0,mac=$macaddr"
		;;
	socket_vmnet)
		[ -n "$socket_vmnet_path" ] || die "net=socket_vmnet requires socket_vmnet_path"
		[ -S "$socket_vmnet_path" ] || die "socket_vmnet_path '$socket_vmnet_path' is not a socket; start socket_vmnet first"
		case $socket_vmnet_mode in
		shared|host|bridged)
			:
			;;
		*)
			die "unsupported socket_vmnet_mode '$socket_vmnet_mode'"
			;;
		esac
		set -- "$@" \
			-netdev "socket,id=net0,fd=3" \
			-device "virtio-net-pci,netdev=net0,mac=$macaddr"
		;;
	none)
		:
		;;
	*)
		die "unsupported net mode '$net'"
		;;
	esac

	if [ "$headless" = "yes" ]; then
		set -- "$@" \
			-nographic \
			-serial mon:stdio \
			-chardev "socket,id=qga,path=$qga_socket,server=on,wait=off" \
			-device virtio-serial \
			-device virtserialport,chardev=qga,name=org.qemu.guest_agent.0
	else
		set -- "$@" \
			-device virtio-gpu-pci \
			-device qemu-xhci \
			-device usb-kbd \
			-device usb-tablet
	fi

	if [ -n "$extra_args" ]; then
		# Intentional word splitting for config-supplied raw QEMU flags.
		# shellcheck disable=SC2086
		set -- "$@" $extra_args
	fi

	if [ "$net" = "socket_vmnet" ]; then
		socket_vmnet_client=$(resolve_socket_vmnet_client)
		set -- "$socket_vmnet_client" "$socket_vmnet_path" "$@"
	fi

	cmd=
	for arg do
		if [ -n "$cmd" ]; then
			cmd="$cmd "
		fi
		cmd=$cmd$(quote_sh "$arg")
	done
	printf '%s\n' "$cmd"
}

run_vm() {
	name=$1
	shift
	cmd=$(assemble_qemu "$name" "$@")
	eval "set -- $cmd"
	exec "$@"
}

start_vm() {
	name=$1
	shift
	cmd=$(assemble_qemu "$name" "$@")
	eval "set -- $cmd"
	set -- "$@" -daemonize
	"$@"
	printf '%s\n' "started $name"
}

stop_vm() {
	name=$1
	load_config "$name"
	[ -f "$pidfile" ] || die "instance '$name' is not running"
	pid=$(cat "$pidfile")
	kill "$pid"
	rm -f "$pidfile" "$qmp_socket" "$qga_socket"
	printf '%s\n' "stopped $name"
}

create_vm() {
	name=$1
	shift
	dir=$(instance_dir "$name")
	[ ! -e "$dir" ] || die "instance '$name' already exists"
	ensure_dirs

	cpus=$(default_cpus)
	macaddr=$(default_mac "$name")
	ssh_port=$(default_ssh_port "$name")
	disk_format=$DISK_FORMAT_DEFAULT
	disk_size=$DISK_SIZE_DEFAULT
	disk=$dir/disk.$disk_format

	write_config "$name" \
		name="$name" \
		qemu="$QEMU_BIN" \
		qemu_img="$QEMU_IMG_BIN" \
		efi="$EFI_DEFAULT" \
		accel="$ACCEL_DEFAULT" \
		machine="$MACHINE_DEFAULT" \
		memory="$MEMORY_DEFAULT" \
		cpus="$cpus" \
		macaddr="$macaddr" \
		ssh_port="$ssh_port" \
		ssh_key="" \
		disk_format="$disk_format" \
		disk_size="$disk_size" \
		disk="$disk" \
		net_iface="" \
		net_iface_mac="" \
		socket_vmnet_path="" \
		socket_vmnet_mode="shared" \
		net="user" \
		headless="yes" \
		boot="menu=on,splash-time=0" \
		extra_args=""

	if [ "$#" -gt 0 ]; then
		tmp=$dir/config.tmp
		cp "$(config_path "$name")" "$tmp"
		for kv do
			key=${kv%%=*}
			value=${kv#*=}
			printf '%s=%s\n' "$key" "$(quote_sh "$value")" >> "$tmp"
		done
		mv "$tmp" "$(config_path "$name")"
	fi

	load_config "$name"
	write_config "$name" \
		name="$name" \
		qemu="$qemu" \
		qemu_img="$qemu_img" \
		efi="$efi" \
		accel="$accel" \
		machine="$machine" \
		memory="$memory" \
		cpus="$cpus" \
		macaddr="$macaddr" \
		ssh_port="$ssh_port" \
		ssh_key="$ssh_key" \
		disk_format="$disk_format" \
		disk_size="${disk_size:-0}" \
		disk="$disk" \
		cdrom="${cdrom:-}" \
		net_iface="$net_iface" \
		net_iface_mac="$net_iface_mac" \
		socket_vmnet_path="$socket_vmnet_path" \
		socket_vmnet_mode="$socket_vmnet_mode" \
		net="$net" \
		headless="$headless" \
		boot="$boot" \
		extra_args="$extra_args"
	mkdir -p "$instance_dir"
	if [ ! -e "$disk" ] && [ "${disk_size:-0}" != "0" ]; then
		"$qemu_img" create -f "$disk_format" "$disk" "$disk_size" >/dev/null
	fi
	printf '%s\n' "created $name"
}

list_vms() {
	ensure_dirs
	found=false
	for dir in "$INSTANCES_DIR"/*; do
		[ -d "$dir" ] || continue
		name=${dir##*/}
		found=true
		if [ -f "$dir/run/qemu.pid" ]; then
			state=running
		else
			state=stopped
		fi
		printf '%-16s %s\n' "$name" "$state"
	done
	$found || printf '%s\n' "no instances"
}

show_vm() {
	name=$1
	require_instance "$name"
	cat "$(config_path "$name")"
}

ssh_vm() {
	name=$1
	shift
	load_config "$name"
	[ "$net" = "user" ] || die "ssh is only supported with net=user; use the guest IP for net=$net"
	ssh_args="-p $(quote_sh "$ssh_port") -o IdentitiesOnly=yes"
	remote_args=
	if [ -n "$ssh_key" ]; then
		ssh_args="$ssh_args -i $(quote_sh "$ssh_key")"
	fi
	while [ "$#" -gt 0 ]; do
		if [ "$1" = "--" ]; then
			shift
			break
		fi
		ssh_args="$ssh_args $(quote_sh "$1")"
		shift
	done
	for arg do
		remote_args="$remote_args $(quote_sh "$arg")"
	done
	eval "exec ssh $ssh_args 127.0.0.1$remote_args"
}

delete_vm() {
	name=$1
	load_config "$name"
	if [ -f "$pidfile" ]; then
		die "instance '$name' is running; stop it first"
	fi
	rm -rf "$instance_dir"
	printf '%s\n' "deleted $name"
}

[ $# -gt 0 ] || {
	usage >&2
	exit 1
}

cmd=$1
shift

case $cmd in
create)
	[ $# -ge 1 ] || die "create requires NAME"
	name=$1
	shift
	create_vm "$name" "$@"
	;;
run)
	[ $# -ge 1 ] || die "run requires NAME"
	name=$1
	shift
	run_vm "$name" "$@"
	;;
start)
	[ $# -ge 1 ] || die "start requires NAME"
	name=$1
	shift
	start_vm "$name" "$@"
	;;
stop)
	[ $# -eq 1 ] || die "stop requires NAME"
	stop_vm "$1"
	;;
ssh)
	[ $# -ge 1 ] || die "ssh requires NAME"
	name=$1
	shift
	ssh_vm "$name" "$@"
	;;
list)
	[ $# -eq 0 ] || die "list takes no arguments"
	list_vms
	;;
show)
	[ $# -eq 1 ] || die "show requires NAME"
	show_vm "$1"
	;;
delete)
	[ $# -eq 1 ] || die "delete requires NAME"
	delete_vm "$1"
	;;
help|-h|--help)
	usage
	;;
	*)
		die "unknown command '$cmd'"
		;;
esac
