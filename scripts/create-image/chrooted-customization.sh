#!/bin/bash
PACKAGES="linux-image-generic lvm2 busybox-static gdisk grub-pc"
eval "$chrooted_functions"
start_failsafe_mode
# in the chroot commands should use /tmp for temporary files
export TMPDIR=/tmp

if [ "$1" = "--debug" ]
then
    debug=1
    shift
else
    debug=0
fi

loop_device=$1
root_password_request=$2

mount_virtual_filesystems
export DEBIAN_FRONTEND=noninteractive LANG=C

# let grub find our virtual device
# we will install the bootloader on the final device anyway,
# this is only useful to avoid warnings
mkdir -p boot/grub
cat > boot/grub/device.map << END_MAP
(hd0) $loop_device
END_MAP

# install missing packages
echo -n "I: draft image - updating package manager database... "
apt-get update -qq
echo done
to_be_installed=""
for package in $PACKAGES
do
    installed=$(dpkg-query -W --showformat='${Status}\n' \
                    $package 2>/dev/null | grep -c "^i" || true)
if [ $installed -eq 0 ]
then
    to_be_installed="$to_be_installed $package"
fi
done
if [ "$to_be_installed" != "" ]
then
    echo -n "I: draft image - installing packages:${to_be_installed}... "
    apt-get -qq --no-install-recommends install $to_be_installed >/dev/null 2>&1
    echo done
fi

apt-get -qq clean
rm -rf /var/lib/apt/lists/*

# for text console in kvm
if [ "$debug" = "1" ]
then   
    # display the grub interface
    cat > ./etc/default/grub << EOF
GRUB_TIMEOUT=4
GRUB_DISTRIBUTOR="debootstick Linux"
GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0,115200n8"
GRUB_TERMINAL=serial
GRUB_SERIAL_COMMAND="serial --speed=115200 --unit=0 --word=8 --parity=no --stop=1"
EOF
    # start a shell when the system is ready
    cat > ./etc/init/ttyS0.conf << EOF
start on stopped rc or RUNLEVEL=[12345]
stop on runlevel [!12345]

respawn
exec /sbin/getty -L 115200 ttyS0 xterm
EOF
fi

# set the root password if requested
case "$root_password_request" in
    "NO_REQUEST")
        true            # nothing to do
    ;;
    "NO_PASSWORD")
        passwd -dq root  # remove root password
    ;;
    *)                  # change root password
        echo "$root_password_request" | chpasswd
    ;;
esac

echo -n "I: draft image - setting up bootloader... "
# work around grub displaying error message with our LVM setup
# note: even if the file etc/grub.d/10_linux is re-created
# after an upgrade of the package grub-common, our script
# 09_linux_custom will be executed first and take precedence.
sed -e 's/quick_boot=.*/quick_boot=0/' etc/grub.d/10_linux > \
        etc/grub.d/09_linux_custom
chmod +x etc/grub.d/09_linux_custom
rm etc/grub.d/10_linux

# install grub on this temporary work-image
# This may not seem useful (it will be repeated on the final
# stick anyway), but actually it is:
# the files created there should be accounted when
# estimating the final stick minimal size).
quiet_grub_install $loop_device

rm boot/grub/device.map
echo done

# umount all
undo_all

