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

usage() {
	cat <<EOF
Usage:
  $PROG create NAME [key=value ...]
  $PROG run NAME [-- qemu-args...]
  $PROG start NAME [-- qemu-args...]
  $PROG stop NAME
  $PROG ssh NAME [ssh-args...]
  $PROG list
  $PROG show NAME
  $PROG delete NAME

Config keys:
  disk, disk_size, disk_format, cdrom, memory, cpus, ssh_port, macaddr
  qemu, qemu_img, efi, accel, machine, net, headless, boot, extra_args

Notes:
  - macOS/Apple Silicon defaults are tuned for aarch64 guests with hvf.
  - 'run' stays in the foreground. 'start' daemonizes and writes a pid file.
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
	macaddr=${macaddr:-$(default_mac "$name")}
	net=${net:-user}
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
	vmnet-shared|vmnet-host|vmnet-bridged)
		set -- "$@" \
			-netdev "$net,id=net0" \
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
		disk_format="$disk_format" \
		disk_size="$disk_size" \
		disk="$disk" \
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
		disk_format="$disk_format" \
		disk_size="${disk_size:-0}" \
		disk="$disk" \
		cdrom="${cdrom:-}" \
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
	exec ssh -p "$ssh_port" "$@" 127.0.0.1
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
