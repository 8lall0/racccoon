# U-Boot distro-boot script source for the Orange Pi RV bring-up — see
# docs/opi-rv-plan.md's Stage 1 section for why this exists and the
# current status.
#
# The vendor U-Boot's distro_bootcmd macro tries extlinux.conf before a
# boot.scr on the same partition (scan_dev_for_boot's `run
# scan_dev_for_extlinux; run scan_dev_for_scripts;`), so this only runs
# once /boot/extlinux/extlinux.conf on the target SD card is renamed out
# of the way (e.g. to extlinux.conf.bak) — see the plan doc for the
# exact steps. The point is to remove the human-reaction-time race of
# manually catching the U-Boot prompt and typing `load`/`bootelf` by
# hand: whatever happens with the SD controller's own probe reliability,
# once it succeeds this runs unattended.
#
# Rebuild after editing:
#   mkimage -A riscv -T script -C none -n "racccoon boot.scr" -d boot.cmd boot.scr
#
# Deploy boot.scr to the SD card's boot partition root (alongside
# kernel_opi.elf), either by swapping the card into another machine or,
# more conveniently, by piping it in as base64 over the already-running
# vendor Debian's serial console:
#   base64 -w0 boot.scr | ssh/serial-paste as:
#   echo '<base64>' | base64 -d | sudo tee /boot/boot.scr > /dev/null

echo "racccoon: loading kernel_opi.elf..."
load mmc 0:1 0x40200000 kernel_opi.elf
bootelf 0x40200000
