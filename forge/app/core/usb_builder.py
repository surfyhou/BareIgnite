"""USB image creation with dual-partition layout for bootable BareIgnite media."""

import asyncio
import logging
import os
import shutil
import tempfile
from pathlib import Path
from typing import Callable, Optional

from config import settings

logger = logging.getLogger(__name__)


class USBBuilder:
    """Creates dual-partition USB images for bootable BareIgnite deployment.

    Layout:
        Partition 1 (boot): FAT32 for EFI + ext4 overlay for Live root
        Partition 2 (data): ext4 containing BareIgnite + OS images
    """

    def __init__(self) -> None:
        self._required_tools = ["parted", "mkfs.fat", "mkfs.ext4", "losetup"]

    def _check_tools(self) -> None:
        """Verify that required system tools are available."""
        missing: list[str] = []
        for tool in self._required_tools:
            if not shutil.which(tool):
                missing.append(tool)
        if missing:
            raise RuntimeError(
                f"Required tools not found: {', '.join(missing)}. "
                f"Install: dnf install dosfstools e2fsprogs parted"
            )

    async def build_usb_image(
        self,
        output_path: Path,
        image_size: int,
        boot_files_dir: Optional[Path] = None,
        data_files_dir: Optional[Path] = None,
        progress_callback: Optional[Callable[[float, str], None]] = None,
    ) -> Path:
        """Create a dual-partition USB disk image.

        Args:
            output_path: Path for the output .img file
            image_size: Total image size in bytes
            boot_files_dir: Directory containing Live boot system files
            data_files_dir: Directory containing BareIgnite data + OS images
            progress_callback: Callback(progress_pct, message)

        Returns:
            Path to the created USB image file
        """
        self._check_tools()
        output_path.parent.mkdir(parents=True, exist_ok=True)

        if progress_callback:
            progress_callback(0.0, "Creating USB disk image")

        # Calculate partition sizes
        # Boot partition: 2GB for Live system (EFI + root)
        boot_size_mb = 2048
        # Data partition: rest of the image
        total_mb = image_size // (1024 * 1024)
        data_size_mb = total_mb - boot_size_mb - 1  # 1MB for GPT/alignment

        if data_size_mb < 512:
            raise ValueError(
                f"Image size too small ({total_mb}MB). "
                f"Need at least {boot_size_mb + 512 + 1}MB for boot + data partitions."
            )

        loop_device: Optional[str] = None
        try:
            # Step 1: Create empty image file
            if progress_callback:
                progress_callback(5.0, f"Creating {total_mb}MB image file")
            await self._create_image_file(output_path, image_size)

            # Step 2: Set up loop device
            if progress_callback:
                progress_callback(10.0, "Setting up loop device")
            loop_device = await self._setup_loop_device(output_path)

            # Step 3: Create GPT partition table
            if progress_callback:
                progress_callback(15.0, "Creating GPT partition table")
            await self._create_partitions(loop_device, boot_size_mb)

            # Step 4: Refresh partition table
            await self._run_cmd(["partprobe", loop_device])
            # Give the kernel a moment to recognize partitions
            await asyncio.sleep(1)

            boot_part = f"{loop_device}p1"
            data_part = f"{loop_device}p2"

            # Step 5: Format partitions
            if progress_callback:
                progress_callback(25.0, "Formatting boot partition (FAT32)")
            await self._format_fat32(boot_part, "BIBOOT")

            if progress_callback:
                progress_callback(30.0, "Formatting data partition (ext4)")
            await self._format_ext4(data_part, "BIDATA")

            # Step 6: Copy boot files
            if boot_files_dir and boot_files_dir.exists():
                if progress_callback:
                    progress_callback(35.0, "Copying boot files")
                await self._copy_to_partition(boot_part, boot_files_dir)

            # Step 7: Copy data files
            if data_files_dir and data_files_dir.exists():
                if progress_callback:
                    progress_callback(50.0, "Copying data files")
                await self._copy_to_partition(data_part, data_files_dir)

            # Step 8: Install GRUB EFI bootloader
            if progress_callback:
                progress_callback(80.0, "Installing GRUB EFI bootloader")
            await self._install_grub_efi(boot_part)

            if progress_callback:
                progress_callback(95.0, "Finalizing image")

        finally:
            # Cleanup loop device
            if loop_device:
                await self._teardown_loop_device(loop_device)

        if progress_callback:
            progress_callback(100.0, "USB image created successfully")

        image_size_actual = output_path.stat().st_size
        logger.info(
            "USB image created: %s (%d bytes / %.1f GB)",
            output_path,
            image_size_actual,
            image_size_actual / (1024 * 1024 * 1024),
        )
        return output_path

    async def _create_image_file(self, path: Path, size: int) -> None:
        """Create a sparse image file of the specified size."""
        await self._run_cmd([
            "dd",
            "if=/dev/zero",
            f"of={path}",
            "bs=1",
            "count=0",
            f"seek={size}",
        ])

    async def _setup_loop_device(self, image_path: Path) -> str:
        """Attach image file to a loop device and return the device path."""
        result = await self._run_cmd_output([
            "losetup", "--find", "--show", "--partscan", str(image_path),
        ])
        loop_device = result.strip()
        if not loop_device.startswith("/dev/loop"):
            raise RuntimeError(f"Unexpected losetup output: {loop_device}")
        logger.info("Loop device: %s -> %s", loop_device, image_path)
        return loop_device

    async def _teardown_loop_device(self, loop_device: str) -> None:
        """Detach a loop device."""
        try:
            await self._run_cmd(["losetup", "-d", loop_device])
            logger.info("Detached loop device: %s", loop_device)
        except RuntimeError as e:
            logger.warning("Failed to detach loop device %s: %s", loop_device, e)

    async def _create_partitions(self, device: str, boot_size_mb: int) -> None:
        """Create GPT partition table with boot (EFI) and data partitions."""
        # Create GPT table
        await self._run_cmd(["parted", "-s", device, "mklabel", "gpt"])

        # Partition 1: EFI System Partition (FAT32)
        await self._run_cmd([
            "parted", "-s", device,
            "mkpart", "primary", "fat32",
            "1MiB", f"{boot_size_mb}MiB",
        ])
        await self._run_cmd([
            "parted", "-s", device,
            "set", "1", "esp", "on",
        ])

        # Partition 2: Data partition (ext4) - rest of the disk
        await self._run_cmd([
            "parted", "-s", device,
            "mkpart", "primary", "ext4",
            f"{boot_size_mb}MiB", "100%",
        ])

    async def _format_fat32(self, partition: str, label: str) -> None:
        """Format a partition as FAT32."""
        await self._run_cmd(["mkfs.fat", "-F32", "-n", label, partition])

    async def _format_ext4(self, partition: str, label: str) -> None:
        """Format a partition as ext4."""
        await self._run_cmd([
            "mkfs.ext4",
            "-F",
            "-L", label,
            "-O", "^metadata_csum",  # Broader compatibility
            partition,
        ])

    async def _copy_to_partition(self, partition: str, source_dir: Path) -> None:
        """Mount a partition, copy files, and unmount."""
        mount_dir = Path(tempfile.mkdtemp(prefix="bareignite_usb_"))
        try:
            await self._run_cmd(["mount", partition, str(mount_dir)])
            # Copy all files from source to mount point
            await asyncio.to_thread(
                shutil.copytree,
                str(source_dir),
                str(mount_dir),
                dirs_exist_ok=True,
            )
            # Sync filesystem
            await self._run_cmd(["sync"])
        finally:
            await self._run_cmd(["umount", str(mount_dir)])
            mount_dir.rmdir()

    async def _install_grub_efi(self, boot_partition: str) -> None:
        """Install GRUB EFI bootloader to the boot partition.

        Creates the EFI/BOOT directory structure and installs GRUB
        for both x86_64 and aarch64 UEFI boot.
        """
        mount_dir = Path(tempfile.mkdtemp(prefix="bareignite_grub_"))
        try:
            await self._run_cmd(["mount", boot_partition, str(mount_dir)])

            efi_boot_dir = mount_dir / "EFI" / "BOOT"
            efi_boot_dir.mkdir(parents=True, exist_ok=True)

            # Check for GRUB EFI binaries on the host system
            grub_efi_candidates = [
                # x86_64 UEFI
                ("/boot/efi/EFI/rocky/grubx64.efi", "BOOTX64.EFI"),
                ("/boot/efi/EFI/centos/grubx64.efi", "BOOTX64.EFI"),
                ("/boot/efi/EFI/BOOT/BOOTX64.EFI", "BOOTX64.EFI"),
                ("/usr/lib/grub/x86_64-efi/grub.efi", "BOOTX64.EFI"),
                # aarch64 UEFI
                ("/boot/efi/EFI/rocky/grubaa64.efi", "BOOTAA64.EFI"),
                ("/boot/efi/EFI/BOOT/BOOTAA64.EFI", "BOOTAA64.EFI"),
                # Shim (for Secure Boot)
                ("/boot/efi/EFI/rocky/shimx64.efi", "shimx64.efi"),
                ("/boot/efi/EFI/centos/shimx64.efi", "shimx64.efi"),
            ]

            copied_any = False
            for src_path, dest_name in grub_efi_candidates:
                if os.path.exists(src_path):
                    dest_path = efi_boot_dir / dest_name
                    if not dest_path.exists():
                        shutil.copy2(src_path, str(dest_path))
                        logger.info("Installed EFI binary: %s -> %s", src_path, dest_name)
                        copied_any = True

            if not copied_any:
                logger.warning(
                    "No GRUB EFI binaries found on host. "
                    "USB may not be UEFI-bootable without manual setup."
                )

            # Create a minimal grub.cfg for the boot partition
            grub_cfg_path = efi_boot_dir / "grub.cfg"
            grub_cfg_content = """\
# BareIgnite GRUB configuration
set timeout=5
set default=0

menuentry "BareIgnite Live System" {
    search --no-floppy --label BIBOOT --set=root
    linuxefi /vmlinuz root=live:LABEL=BIBOOT rd.live.image
    initrdefi /initrd.img
}

menuentry "Boot from local disk" {
    exit
}
"""
            grub_cfg_path.write_text(grub_cfg_content, encoding="utf-8")

            await self._run_cmd(["sync"])

        finally:
            await self._run_cmd(["umount", str(mount_dir)])
            mount_dir.rmdir()

    async def _run_cmd(self, cmd: list[str]) -> None:
        """Run a subprocess command, raising RuntimeError on failure."""
        logger.debug("Running: %s", " ".join(cmd))
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await process.communicate()
        if process.returncode != 0:
            error = stderr.decode("utf-8", errors="replace")
            raise RuntimeError(
                f"Command failed (exit {process.returncode}): {' '.join(cmd)}\n{error}"
            )

    async def _run_cmd_output(self, cmd: list[str]) -> str:
        """Run a subprocess command and return stdout."""
        logger.debug("Running: %s", " ".join(cmd))
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await process.communicate()
        if process.returncode != 0:
            error = stderr.decode("utf-8", errors="replace")
            raise RuntimeError(
                f"Command failed (exit {process.returncode}): {' '.join(cmd)}\n{error}"
            )
        return stdout.decode("utf-8", errors="replace")
