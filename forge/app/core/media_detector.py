"""Removable media detection for USB drives and optical (DVD/BD) writers."""

import asyncio
import json
import logging
import os
from pathlib import Path
from typing import Optional

from models.component import MediaDevice

logger = logging.getLogger(__name__)


class MediaDetector:
    """Detects connected USB block devices and optical drives.

    Uses Linux /sys/block and lsblk for device enumeration.
    """

    def __init__(self) -> None:
        pass

    async def detect_usb_devices(self) -> list[MediaDevice]:
        """List connected USB block devices suitable for writing.

        Filters out:
            - Non-removable devices (hard drives)
            - Loop devices
            - CD/DVD devices (handled by detect_optical_drives)
            - Partitions (only returns whole-disk devices)

        Returns:
            List of MediaDevice objects for USB drives
        """
        devices: list[MediaDevice] = []

        try:
            lsblk_data = await self._run_lsblk()
        except RuntimeError:
            # lsblk not available, fall back to /sys/block
            return await self._detect_usb_from_sysblock()

        for block_dev in lsblk_data:
            name = block_dev.get("name", "")
            dev_type = block_dev.get("type", "")
            rm = block_dev.get("rm", False)  # removable flag
            ro = block_dev.get("ro", False)  # read-only flag
            tran = block_dev.get("tran", "")  # transport (usb, sata, etc.)

            # Only whole disks that are removable or USB
            if dev_type != "disk":
                continue
            if ro:
                continue
            # Include USB or explicitly removable devices
            if not (tran == "usb" or rm):
                continue
            # Skip if it looks like an optical drive
            if name.startswith("sr") or name.startswith("cd"):
                continue

            device_path = f"/dev/{name}"
            size = block_dev.get("size", 0)
            model = block_dev.get("model", "").strip()
            vendor = block_dev.get("vendor", "").strip()

            # Check mount status
            mount_points = self._get_mount_points(block_dev)
            mounted = len(mount_points) > 0

            device = MediaDevice(
                device=device_path,
                model=model,
                size=size,
                size_human=self._format_size(size),
                vendor=vendor,
                removable=rm,
                mounted=mounted,
                mount_points=mount_points,
                device_type="usb",
            )
            devices.append(device)

        logger.info("Detected %d USB device(s)", len(devices))
        return devices

    async def detect_optical_drives(self) -> list[MediaDevice]:
        """List connected DVD/Blu-ray optical drives.

        Returns:
            List of MediaDevice objects for optical drives
        """
        devices: list[MediaDevice] = []

        try:
            lsblk_data = await self._run_lsblk()
        except RuntimeError:
            return await self._detect_optical_from_sysblock()

        for block_dev in lsblk_data:
            name = block_dev.get("name", "")
            dev_type = block_dev.get("type", "")

            # sr devices are SCSI CD/DVD, type "rom"
            if dev_type != "rom" and not name.startswith("sr"):
                continue

            device_path = f"/dev/{name}"
            size = block_dev.get("size", 0)
            model = block_dev.get("model", "").strip()
            vendor = block_dev.get("vendor", "").strip()

            mount_points = self._get_mount_points(block_dev)
            mounted = len(mount_points) > 0

            device = MediaDevice(
                device=device_path,
                model=model,
                size=size,
                size_human=self._format_size(size),
                vendor=vendor,
                removable=True,
                mounted=mounted,
                mount_points=mount_points,
                device_type="optical",
            )
            devices.append(device)

        logger.info("Detected %d optical drive(s)", len(devices))
        return devices

    async def get_device_info(self, device_path: str) -> Optional[MediaDevice]:
        """Get detailed info about a specific block device.

        Args:
            device_path: Device path like /dev/sdb

        Returns:
            MediaDevice if found, None otherwise
        """
        dev_name = os.path.basename(device_path)

        try:
            lsblk_data = await self._run_lsblk()
        except RuntimeError:
            return None

        for block_dev in lsblk_data:
            if block_dev.get("name") == dev_name:
                size = block_dev.get("size", 0)
                model = block_dev.get("model", "").strip()
                vendor = block_dev.get("vendor", "").strip()
                rm = block_dev.get("rm", False)
                dev_type = block_dev.get("type", "")
                mount_points = self._get_mount_points(block_dev)

                media_type = "optical" if dev_type == "rom" else "usb"

                return MediaDevice(
                    device=device_path,
                    model=model,
                    size=size,
                    size_human=self._format_size(size),
                    vendor=vendor,
                    removable=rm,
                    mounted=len(mount_points) > 0,
                    mount_points=mount_points,
                    device_type=media_type,
                )

        return None

    async def _run_lsblk(self) -> list[dict]:
        """Run lsblk and return parsed JSON output.

        Returns:
            List of block device dictionaries
        """
        cmd = [
            "lsblk",
            "--json",
            "--bytes",
            "--output", "NAME,TYPE,SIZE,MODEL,VENDOR,RM,RO,TRAN,MOUNTPOINTS",
            "--paths",
        ]

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await process.communicate()

        if process.returncode != 0:
            raise RuntimeError(
                f"lsblk failed: {stderr.decode('utf-8', errors='replace')}"
            )

        data = json.loads(stdout.decode("utf-8"))
        devices = data.get("blockdevices", [])

        # Normalize: lsblk --paths includes full path in name field
        for dev in devices:
            name = dev.get("name", "")
            if name.startswith("/dev/"):
                dev["name"] = name.replace("/dev/", "")

        return devices

    async def _detect_usb_from_sysblock(self) -> list[MediaDevice]:
        """Fallback USB detection via /sys/block when lsblk is unavailable."""
        devices: list[MediaDevice] = []
        sys_block = Path("/sys/block")

        if not sys_block.exists():
            return devices

        for dev_dir in sorted(sys_block.iterdir()):
            dev_name = dev_dir.name
            # Skip loop, dm, sr, and other non-disk devices
            if any(dev_name.startswith(p) for p in ("loop", "dm-", "sr", "cd", "ram")):
                continue

            removable_path = dev_dir / "removable"
            if removable_path.exists():
                try:
                    removable = removable_path.read_text().strip() == "1"
                except OSError:
                    removable = False
            else:
                removable = False

            if not removable:
                continue

            # Read size (in 512-byte sectors)
            size_path = dev_dir / "size"
            size = 0
            if size_path.exists():
                try:
                    size = int(size_path.read_text().strip()) * 512
                except (ValueError, OSError):
                    pass

            # Read model
            model = ""
            model_path = dev_dir / "device" / "model"
            if model_path.exists():
                try:
                    model = model_path.read_text().strip()
                except OSError:
                    pass

            # Read vendor
            vendor = ""
            vendor_path = dev_dir / "device" / "vendor"
            if vendor_path.exists():
                try:
                    vendor = vendor_path.read_text().strip()
                except OSError:
                    pass

            device = MediaDevice(
                device=f"/dev/{dev_name}",
                model=model,
                size=size,
                size_human=self._format_size(size),
                vendor=vendor,
                removable=True,
                mounted=False,
                device_type="usb",
            )
            devices.append(device)

        return devices

    async def _detect_optical_from_sysblock(self) -> list[MediaDevice]:
        """Fallback optical drive detection via /sys/block."""
        devices: list[MediaDevice] = []
        sys_block = Path("/sys/block")

        if not sys_block.exists():
            return devices

        for dev_dir in sorted(sys_block.iterdir()):
            dev_name = dev_dir.name
            if not dev_name.startswith("sr"):
                continue

            model = ""
            model_path = dev_dir / "device" / "model"
            if model_path.exists():
                try:
                    model = model_path.read_text().strip()
                except OSError:
                    pass

            device = MediaDevice(
                device=f"/dev/{dev_name}",
                model=model,
                size=0,
                size_human="0 B",
                removable=True,
                mounted=False,
                device_type="optical",
            )
            devices.append(device)

        return devices

    @staticmethod
    def _get_mount_points(block_dev: dict) -> list[str]:
        """Extract mount points from lsblk device data.

        Handles both the device itself and its children (partitions).
        """
        mounts: list[str] = []

        # Check the device's own mountpoints
        dev_mounts = block_dev.get("mountpoints", [])
        if isinstance(dev_mounts, list):
            mounts.extend([m for m in dev_mounts if m])
        elif dev_mounts:
            mounts.append(str(dev_mounts))

        # Check children (partitions)
        for child in block_dev.get("children", []):
            child_mounts = child.get("mountpoints", [])
            if isinstance(child_mounts, list):
                mounts.extend([m for m in child_mounts if m])
            elif child_mounts:
                mounts.append(str(child_mounts))

        return mounts

    @staticmethod
    def _format_size(size_bytes: int) -> str:
        """Format byte count to human-readable string."""
        if size_bytes == 0:
            return "0 B"
        units = ["B", "KB", "MB", "GB", "TB"]
        unit_idx = 0
        size_f = float(size_bytes)
        while size_f >= 1024 and unit_idx < len(units) - 1:
            size_f /= 1024
            unit_idx += 1
        return f"{size_f:.1f} {units[unit_idx]}"
