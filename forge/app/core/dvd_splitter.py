"""DVD multi-disc splitting for large BareIgnite deployments."""

import logging
import shutil
import tempfile
from datetime import datetime
from pathlib import Path
from typing import Callable, Optional

from config import settings
from core.iso_builder import ISOBuilder

logger = logging.getLogger(__name__)

# DVD-5 capacity in decimal bytes (4.7 GB)
DVD_CAPACITY = 4_700_000_000


class DiscPlan:
    """Represents the contents planned for a single DVD disc."""

    def __init__(self, disc_number: int) -> None:
        self.disc_number: int = disc_number
        self.files: list[tuple[str, Path, int]] = []  # (label, path, size)
        self.total_size: int = 0
        self.is_bootable: bool = False

    def add_file(self, label: str, path: Path, size: int) -> None:
        """Add a file to this disc's plan."""
        self.files.append((label, path, size))
        self.total_size += size

    @property
    def remaining_space(self) -> int:
        """Bytes of space remaining on this disc."""
        return max(0, DVD_CAPACITY - self.total_size)


class DVDSplitter:
    """Splits BareIgnite packages across multiple DVD-sized ISO images.

    Disc 1 is always bootable and contains:
        - Live boot system
        - BareIgnite base (scripts, templates, configs)
        - PXE boot files
        - Tools (yq, jq, ansible)
    Disc 2+ contain:
        - OS images split by size to fit on DVDs
        - Manifest files describing contents
    """

    def __init__(self) -> None:
        self._iso_builder = ISOBuilder()

    def calculate_split(
        self,
        base_files_dir: Path,
        image_files: list[tuple[str, Path]],
        boot_overhead: int = 500 * 1024 * 1024,  # 500MB for boot + base
    ) -> list[DiscPlan]:
        """Determine how many discs are needed and what goes on each.

        Args:
            base_files_dir: Directory with BareIgnite base, PXE, tools
            image_files: List of (label, path) tuples for OS images
            boot_overhead: Space reserved on disc 1 for boot system and base files

        Returns:
            List of DiscPlan objects describing the disc layout
        """
        discs: list[DiscPlan] = []

        # Disc 1: bootable with base files
        disc1 = DiscPlan(disc_number=1)
        disc1.is_bootable = True

        # Calculate base files size
        base_size = self._dir_size(base_files_dir) if base_files_dir.exists() else 0
        actual_overhead = max(boot_overhead, base_size + settings.iso_overhead)
        disc1.total_size = actual_overhead  # Reserve space
        discs.append(disc1)

        # Sort images by size (largest first) for better bin-packing
        sorted_images = sorted(
            image_files,
            key=lambda x: x[1].stat().st_size if x[1].exists() else 0,
            reverse=True,
        )

        for label, image_path in sorted_images:
            if not image_path.exists():
                logger.warning("Image file not found, skipping: %s", image_path)
                continue

            file_size = image_path.stat().st_size

            if file_size > DVD_CAPACITY - settings.iso_overhead:
                logger.error(
                    "Image %s (%d bytes / %.1f GB) exceeds DVD capacity, cannot split",
                    label,
                    file_size,
                    file_size / (1024 * 1024 * 1024),
                )
                continue

            # Try to fit on an existing disc (first-fit decreasing)
            placed = False
            for disc in discs:
                needed = file_size + settings.iso_overhead  # Per-file overhead
                if disc.remaining_space >= needed:
                    disc.add_file(label, image_path, file_size)
                    placed = True
                    break

            if not placed:
                # Need a new disc
                new_disc = DiscPlan(disc_number=len(discs) + 1)
                new_disc.add_file(label, image_path, file_size)
                discs.append(new_disc)

        total_discs = len(discs)
        logger.info(
            "Split plan: %d disc(s) for %d images",
            total_discs,
            len(sorted_images),
        )
        for disc in discs:
            logger.info(
                "  Disc %d: %d files, %.1f MB (%.1f%% full)%s",
                disc.disc_number,
                len(disc.files),
                disc.total_size / (1024 * 1024),
                disc.total_size / DVD_CAPACITY * 100,
                " [BOOT]" if disc.is_bootable else "",
            )

        return discs

    async def split_and_build(
        self,
        output_dir: Path,
        base_files_dir: Path,
        image_files: list[tuple[str, Path]],
        volume_prefix: str = "BAREIGNITE",
        progress_callback: Optional[Callable[[float, str], None]] = None,
    ) -> list[Path]:
        """Create multiple DVD ISO files according to the split plan.

        Args:
            output_dir: Directory to write ISO files into
            base_files_dir: Directory with BareIgnite base files
            image_files: List of (label, path) for OS images
            volume_prefix: Prefix for ISO volume labels
            progress_callback: Callback(progress_pct, message)

        Returns:
            List of paths to created ISO files
        """
        output_dir.mkdir(parents=True, exist_ok=True)
        discs = self.calculate_split(base_files_dir, image_files)

        if not discs:
            raise ValueError("No discs to build - no valid image files provided")

        iso_files: list[Path] = []
        total_discs = len(discs)

        for i, disc in enumerate(discs):
            disc_progress_base = (i / total_discs) * 100
            disc_progress_span = (1 / total_discs) * 100

            if progress_callback:
                progress_callback(
                    disc_progress_base,
                    f"Building disc {disc.disc_number} of {total_discs}",
                )

            # Create staging directory for this disc
            staging = Path(tempfile.mkdtemp(prefix=f"bareignite_dvd{disc.disc_number}_"))

            try:
                if disc.is_bootable:
                    # Copy base files (boot system, BareIgnite, PXE, tools)
                    if base_files_dir.exists():
                        shutil.copytree(
                            str(base_files_dir),
                            str(staging),
                            dirs_exist_ok=True,
                        )

                # Copy image files assigned to this disc
                images_dir = staging / "images"
                images_dir.mkdir(parents=True, exist_ok=True)

                for label, image_path in disc.files:
                    dest = images_dir / image_path.name
                    if progress_callback:
                        msg = f"Disc {disc.disc_number}: copying {label}"
                        pct = disc_progress_base + disc_progress_span * 0.3
                        progress_callback(pct, msg)

                    shutil.copy2(str(image_path), str(dest))

                # Generate manifest
                manifest_path = staging / "manifest.txt"
                self._generate_manifest(disc, manifest_path, total_discs)

                # Build ISO
                volume_label = f"{volume_prefix}_D{disc.disc_number}"
                iso_filename = f"bareignite_disc{disc.disc_number}_of_{total_discs}.iso"
                iso_path = output_dir / iso_filename

                if progress_callback:
                    pct = disc_progress_base + disc_progress_span * 0.5
                    progress_callback(pct, f"Creating ISO for disc {disc.disc_number}")

                if disc.is_bootable:
                    # Check for EFI image in the staging area
                    efi_image = staging / "EFI" / "BOOT" / "efiboot.img"
                    efi_param = efi_image if efi_image.exists() else None

                    await self._iso_builder.build_boot_iso(
                        output_path=iso_path,
                        source_dir=staging,
                        volume_label=volume_label,
                        efi_image=efi_param,
                    )
                else:
                    await self._iso_builder.build_data_iso(
                        output_path=iso_path,
                        source_dir=staging,
                        volume_label=volume_label,
                    )

                iso_files.append(iso_path)

            finally:
                # Cleanup staging directory
                shutil.rmtree(staging, ignore_errors=True)

        if progress_callback:
            progress_callback(100.0, f"All {total_discs} disc(s) created")

        logger.info(
            "DVD split complete: %d ISO files in %s",
            len(iso_files),
            output_dir,
        )
        return iso_files

    def _generate_manifest(
        self,
        disc: DiscPlan,
        manifest_path: Path,
        total_discs: int,
    ) -> None:
        """Create a manifest.txt file for a disc.

        Contains disc number, total disc count, and file listing.
        """
        lines = [
            f"BareIgnite Media - Disc {disc.disc_number} of {total_discs}",
            f"Created: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}",
            f"Type: {'Bootable' if disc.is_bootable else 'Data'}",
            "",
            "Contents:",
            "-" * 60,
        ]

        for label, path, size in disc.files:
            size_mb = size / (1024 * 1024)
            lines.append(f"  {label:<40s} {size_mb:>10.1f} MB")

        lines.extend([
            "-" * 60,
            f"Total: {disc.total_size / (1024 * 1024):>10.1f} MB",
            f"Capacity used: {disc.total_size / DVD_CAPACITY * 100:.1f}%",
            "",
        ])

        if disc.is_bootable:
            lines.extend([
                "This disc is bootable. Boot from this disc to start",
                "the BareIgnite Live provisioning environment.",
                "",
                "Insert data discs when prompted during setup.",
            ])
        else:
            lines.extend([
                "This is a data disc. Insert when prompted by the",
                "BareIgnite setup process.",
            ])

        manifest_path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    @staticmethod
    def _dir_size(path: Path) -> int:
        """Calculate total size of all files in a directory tree."""
        total = 0
        for item in path.rglob("*"):
            if item.is_file():
                total += item.stat().st_size
        return total
