"""ISO image creation using xorriso or mkisofs."""

import asyncio
import logging
import os
import shutil
import tempfile
from pathlib import Path
from typing import Callable, Optional

from config import settings

logger = logging.getLogger(__name__)


class ISOBuilder:
    """Creates bootable and data-only ISO images."""

    def __init__(self) -> None:
        self._xorriso_path: Optional[str] = shutil.which("xorriso")
        self._mkisofs_path: Optional[str] = shutil.which("mkisofs") or shutil.which(
            "genisoimage"
        )

    def _get_iso_tool(self) -> str:
        """Return the path to the best available ISO creation tool."""
        if self._xorriso_path:
            return self._xorriso_path
        if self._mkisofs_path:
            return self._mkisofs_path
        raise RuntimeError(
            "No ISO creation tool found. Install xorriso or mkisofs."
        )

    async def build_boot_iso(
        self,
        output_path: Path,
        source_dir: Path,
        volume_label: str = "BAREIGNITE",
        efi_image: Optional[Path] = None,
        progress_callback: Optional[Callable[[float, str], None]] = None,
    ) -> Path:
        """Create a bootable Live ISO with BareIgnite.

        Creates an ISO with both BIOS (isolinux/syslinux) and UEFI (El Torito EFI)
        boot support.

        Args:
            output_path: Path where the ISO file will be written
            source_dir: Directory containing the ISO filesystem contents
            volume_label: ISO volume label
            efi_image: Path to EFI boot image (efiboot.img) for UEFI boot
            progress_callback: Callback(progress_pct, message) for progress updates

        Returns:
            Path to the created ISO file
        """
        output_path.parent.mkdir(parents=True, exist_ok=True)

        if progress_callback:
            progress_callback(0.0, "Preparing ISO filesystem")

        tool = self._get_iso_tool()

        if "xorriso" in tool:
            cmd = await self._build_xorriso_cmd(
                tool, output_path, source_dir, volume_label, efi_image
            )
        else:
            cmd = await self._build_mkisofs_cmd(
                tool, output_path, source_dir, volume_label, efi_image
            )

        if progress_callback:
            progress_callback(10.0, f"Running {os.path.basename(tool)}")

        logger.info("Building boot ISO: %s", " ".join(cmd))
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        stdout, stderr = await process.communicate()

        if process.returncode != 0:
            error_msg = stderr.decode("utf-8", errors="replace")
            logger.error("ISO creation failed: %s", error_msg)
            raise RuntimeError(f"ISO creation failed (exit {process.returncode}): {error_msg}")

        if not output_path.exists():
            raise RuntimeError(f"ISO file was not created at {output_path}")

        if progress_callback:
            progress_callback(100.0, "ISO created successfully")

        iso_size = output_path.stat().st_size
        logger.info(
            "Boot ISO created: %s (%d bytes / %.1f MB)",
            output_path,
            iso_size,
            iso_size / (1024 * 1024),
        )
        return output_path

    async def build_data_iso(
        self,
        output_path: Path,
        source_dir: Path,
        volume_label: str = "BAREIGNITE_DATA",
        progress_callback: Optional[Callable[[float, str], None]] = None,
    ) -> Path:
        """Create a data-only (non-bootable) ISO image.

        Args:
            output_path: Path where the ISO file will be written
            source_dir: Directory containing the data files
            volume_label: ISO volume label
            progress_callback: Callback for progress updates

        Returns:
            Path to the created ISO file
        """
        output_path.parent.mkdir(parents=True, exist_ok=True)

        if progress_callback:
            progress_callback(0.0, "Preparing data ISO")

        tool = self._get_iso_tool()

        if "xorriso" in tool:
            cmd = [
                tool,
                "-as", "mkisofs",
                "-R", "-J",
                "-V", volume_label,
                "-o", str(output_path),
                str(source_dir),
            ]
        else:
            cmd = [
                tool,
                "-R", "-J",
                "-V", volume_label,
                "-o", str(output_path),
                str(source_dir),
            ]

        if progress_callback:
            progress_callback(10.0, f"Running {os.path.basename(tool)}")

        logger.info("Building data ISO: %s", " ".join(cmd))
        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        stdout, stderr = await process.communicate()

        if process.returncode != 0:
            error_msg = stderr.decode("utf-8", errors="replace")
            raise RuntimeError(f"Data ISO creation failed: {error_msg}")

        if progress_callback:
            progress_callback(100.0, "Data ISO created successfully")

        iso_size = output_path.stat().st_size
        logger.info(
            "Data ISO created: %s (%d bytes / %.1f MB)",
            output_path,
            iso_size,
            iso_size / (1024 * 1024),
        )
        return output_path

    async def _build_xorriso_cmd(
        self,
        tool: str,
        output_path: Path,
        source_dir: Path,
        volume_label: str,
        efi_image: Optional[Path],
    ) -> list[str]:
        """Build xorriso command for bootable ISO creation.

        Supports both BIOS boot (via isolinux) and UEFI boot (via El Torito EFI).
        """
        cmd = [
            tool,
            "-as", "mkisofs",
            "-R", "-J",
            "-V", volume_label,
            "-o", str(output_path),
        ]

        # BIOS boot support via isolinux
        isolinux_bin = source_dir / "isolinux" / "isolinux.bin"
        isolinux_cat = source_dir / "isolinux" / "boot.cat"
        if isolinux_bin.exists():
            cmd.extend([
                "-b", "isolinux/isolinux.bin",
                "-c", "isolinux/boot.cat",
                "-no-emul-boot",
                "-boot-load-size", "4",
                "-boot-info-table",
            ])

        # UEFI boot support via El Torito
        if efi_image and efi_image.exists():
            # Make relative path from source_dir
            try:
                efi_rel = efi_image.relative_to(source_dir)
            except ValueError:
                # Copy EFI image into source tree
                efi_dest = source_dir / "EFI" / "BOOT" / "efiboot.img"
                efi_dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(str(efi_image), str(efi_dest))
                efi_rel = efi_dest.relative_to(source_dir)

            cmd.extend([
                "-eltorito-alt-boot",
                "-e", str(efi_rel),
                "-no-emul-boot",
            ])

        # Hybrid MBR for USB boot (isohybrid-compatible)
        cmd.extend([
            "-isohybrid-mbr",
            "/usr/share/syslinux/isohdpfx.bin",
        ])

        # Check if isohdpfx.bin exists; if not, remove those flags
        if not Path("/usr/share/syslinux/isohdpfx.bin").exists():
            # Remove the isohybrid-mbr flags since the file is missing
            try:
                idx = cmd.index("-isohybrid-mbr")
                cmd.pop(idx)  # Remove -isohybrid-mbr
                cmd.pop(idx)  # Remove the path
            except ValueError:
                pass

        cmd.append(str(source_dir))
        return cmd

    async def _build_mkisofs_cmd(
        self,
        tool: str,
        output_path: Path,
        source_dir: Path,
        volume_label: str,
        efi_image: Optional[Path],
    ) -> list[str]:
        """Build mkisofs/genisoimage command for bootable ISO creation."""
        cmd = [
            tool,
            "-R", "-J",
            "-V", volume_label,
            "-o", str(output_path),
        ]

        # BIOS boot
        isolinux_bin = source_dir / "isolinux" / "isolinux.bin"
        if isolinux_bin.exists():
            cmd.extend([
                "-b", "isolinux/isolinux.bin",
                "-c", "isolinux/boot.cat",
                "-no-emul-boot",
                "-boot-load-size", "4",
                "-boot-info-table",
            ])

        # UEFI boot
        if efi_image and efi_image.exists():
            try:
                efi_rel = efi_image.relative_to(source_dir)
            except ValueError:
                efi_dest = source_dir / "EFI" / "BOOT" / "efiboot.img"
                efi_dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(str(efi_image), str(efi_dest))
                efi_rel = efi_dest.relative_to(source_dir)

            cmd.extend([
                "-eltorito-alt-boot",
                "-e", str(efi_rel),
                "-no-emul-boot",
            ])

        cmd.append(str(source_dir))
        return cmd

    async def extract_iso(
        self,
        iso_path: Path,
        dest_dir: Path,
    ) -> Path:
        """Extract the contents of an ISO image to a directory.

        Args:
            iso_path: Path to the ISO file
            dest_dir: Destination directory

        Returns:
            Path to the extraction directory
        """
        dest_dir.mkdir(parents=True, exist_ok=True)

        tool = self._get_iso_tool()
        if "xorriso" in tool:
            cmd = [
                tool,
                "-osirrox", "on",
                "-indev", str(iso_path),
                "-extract", "/", str(dest_dir),
            ]
        else:
            # Use mount + copy as fallback
            mount_dir = Path(tempfile.mkdtemp(prefix="bareignite_iso_"))
            try:
                mount_proc = await asyncio.create_subprocess_exec(
                    "mount", "-o", "loop,ro", str(iso_path), str(mount_dir),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                await mount_proc.communicate()
                if mount_proc.returncode != 0:
                    raise RuntimeError(f"Failed to mount ISO: {iso_path}")

                await asyncio.to_thread(
                    shutil.copytree, str(mount_dir), str(dest_dir), dirs_exist_ok=True
                )
            finally:
                umount_proc = await asyncio.create_subprocess_exec(
                    "umount", str(mount_dir),
                    stdout=asyncio.subprocess.PIPE,
                    stderr=asyncio.subprocess.PIPE,
                )
                await umount_proc.communicate()
                mount_dir.rmdir()
            return dest_dir

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await process.communicate()
        if process.returncode != 0:
            raise RuntimeError(
                f"ISO extraction failed: {stderr.decode('utf-8', errors='replace')}"
            )

        return dest_dir
