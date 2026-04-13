# passthrough

## guest launching

minimal kvm guest with virtio storage and networking:

```sh
qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -smp 4,sockets=1,cores=4,threads=1 \
  -m 8G \
  -drive file=/mnt/storage/vms/guest.img,format=raw,if=virtio,cache=none,aio=io_uring \
  -netdev bridge,id=net0,br=br0 \
  -device virtio-net-pci,netdev=net0 \
  -monitor unix:/run/vms/guest.sock,server,nowait \
  -pidfile /run/vms/guest.pid
```

## cpu isolation

pin qemu to isolated cores:

```sh
taskset -c 2-5 qemu-system-x86_64 ...
```

## hugepages

back guest ram with hugepages:

```sh
-m <ram> \
-mem-prealloc \
-object memory-backend-file,id=mem0,size=<ram>,mem-path=/dev/hugepages,share=on,prealloc=on \
-numa node,memdev=mem0
```

## device passthrough

pass a pci device (e.g. gpu) to the guest:

```sh
-device vfio-pci,host=01:00.0,multifunction=on,x-vga=on \
-device vfio-pci,host=01:00.1
```

verify bdf addresses via `lspci -nn`.

## process hardening

run qemu under the `vmrunner` account:

```sh
# use -runas or su/sudo from launch script
-runas vmrunner
```

enable seccomp sandbox:

```sh
-sandbox on,obsolete=deny,elevateprivileges=deny,spawn=deny,resourcecontrol=deny
```
