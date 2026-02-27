"""Build orchestrator that coordinates ISO/USB/DVD creation."""

import asyncio
import logging
import shutil
import tempfile
import uuid
from datetime import datetime
from pathlib import Path
from typing import Optional

from config import settings
from core.dvd_splitter import DVDSplitter
from core.image_manager import image_manager
from core.iso_builder import ISOBuilder
from core.usb_builder import USBBuilder
from models.build_job import BuildJob, BuildRequest

logger = logging.getLogger(__name__)


class Packager:
    """Orchestrates the build pipeline for creating deployment media.

    Coordinates between ImageManager (cached images), ISOBuilder,
    USBBuilder, and DVDSplitter to produce final output.
    """

    def __init__(self) -> None:
        self._jobs: dict[str, BuildJob] = {}
        self._tasks: dict[str, asyncio.Task[None]] = {}
        self._iso_builder = ISOBuilder()
        self._usb_builder = USBBuilder()
        self._dvd_splitter = DVDSplitter()
        self._lock = asyncio.Lock()

    def create_build(self, request: BuildRequest) -> BuildJob:
        """Create a new build job and start it in the background.

        Args:
            request: Build parameters

        Returns:
            The created BuildJob with pending status
        """
        job_id = str(uuid.uuid4())[:8]
        job = BuildJob(
            id=job_id,
            status="pending",
            os_list=request.os_list,
            arch_list=request.arch_list,
            media_type=request.media_type,
            target_size=request.target_size,
            created_at=datetime.now(),
        )

        self._jobs[job_id] = job

        # Start background build task
        task = asyncio.create_task(self._run_build(job_id))
        self._tasks[job_id] = task

        logger.info(
            "Created build job %s: media=%s, os=%s, arch=%s",
            job_id,
            request.media_type,
            request.os_list,
            request.arch_list,
        )
        return job

    async def _run_build(self, job_id: str) -> None:
        """Execute the full build pipeline for a job.

        Steps:
            1. Verify all requested images are cached
            2. Calculate total size
            3. Prepare staging directory with BareIgnite base files
            4. Based on media_type, invoke appropriate builder
            5. Update progress throughout
        """
        job = self._jobs[job_id]
        job.status = "running"
        self._log(job, "Build started")

        staging_dir: Optional[Path] = None

        try:
            # Step 1: Verify all requested images are cached
            self._log(job, "Verifying cached images")
            job.progress = 5.0
            image_files: list[tuple[str, Path]] = []

            for os_id in job.os_list:
                for arch in job.arch_list:
                    # Try finding the image with various ID patterns
                    image = self._find_cached_image(os_id, arch)
                    if not image:
                        raise ValueError(
                            f"Image not cached: {os_id} ({arch}). "
                            f"Download it first via the images API."
                        )
                    if not image.iso_path or not Path(image.iso_path).exists():
                        raise ValueError(
                            f"Cached image file missing for {os_id}: {image.iso_path}"
                        )
                    image_files.append((image.id, Path(image.iso_path)))
                    self._log(job, f"  Found: {image.id} ({image.size} bytes)")

            if not image_files:
                raise ValueError("No valid images found for the build")

            # Step 2: Calculate total size
            total_size = sum(
                path.stat().st_size for _, path in image_files if path.exists()
            )
            job.total_size = total_size
            self._log(
                job,
                f"Total image size: {total_size / (1024*1024*1024):.2f} GB"
            )
            job.progress = 10.0

            # Step 3: Prepare staging directory with BareIgnite base
            staging_dir = Path(tempfile.mkdtemp(prefix=f"bareignite_build_{job_id}_"))
            self._log(job, "Preparing staging directory")
            await self._prepare_base_files(staging_dir)
            job.progress = 15.0

            # Step 4: Build based on media type
            build_dir = settings.builds_dir / job_id
            build_dir.mkdir(parents=True, exist_ok=True)

            if job.media_type == "usb":
                await self._build_usb(job, staging_dir, image_files, build_dir)
            elif job.media_type == "dvd":
                await self._build_dvd(job, staging_dir, image_files, build_dir)
            elif job.media_type == "data":
                await self._build_data(job, staging_dir, image_files, build_dir)
            else:
                raise ValueError(f"Unknown media type: {job.media_type}")

            # Step 5: Complete
            job.status = "completed"
            job.completed_at = datetime.now()
            job.progress = 100.0
            self._log(job, "Build completed successfully")

        except asyncio.CancelledError:
            job.status = "cancelled"
            job.error = "Build was cancelled"
            self._log(job, "Build cancelled")
            raise

        except Exception as e:
            job.status = "failed"
            job.error = str(e)
            self._log(job, f"Build failed: {e}")
            logger.exception("Build %s failed", job_id)

        finally:
            # Cleanup staging directory
            if staging_dir and staging_dir.exists():
                shutil.rmtree(staging_dir, ignore_errors=True)

    async def _build_usb(
        self,
        job: BuildJob,
        staging_dir: Path,
        image_files: list[tuple[str, Path]],
        build_dir: Path,
    ) -> None:
        """Build a USB disk image."""
        self._log(job, "Building USB image")

        # Prepare data directory: copy images into staging
        data_dir = staging_dir / "data"
        images_dest = data_dir / "images"
        images_dest.mkdir(parents=True, exist_ok=True)

        for label, src_path in image_files:
            self._log(job, f"  Copying {label}")
            dest_path = images_dest / src_path.name
            await asyncio.to_thread(shutil.copy2, str(src_path), str(dest_path))

        job.progress = 40.0

        # Calculate image size
        target_size = job.target_size
        if not target_size:
            # Auto-size: total content + 2GB boot + 10% overhead
            content_size = self._dir_size(staging_dir)
            target_size = content_size + 2 * 1024 * 1024 * 1024  # +2GB
            target_size = int(target_size * 1.1)  # +10% overhead

        if target_size < settings.usb_min_size:
            target_size = settings.usb_min_size

        output_path = build_dir / "bareignite.img"
        self._log(
            job,
            f"Creating USB image: {target_size / (1024*1024*1024):.1f} GB"
        )

        # Use boot files from staging/boot and data from staging/data
        boot_dir = staging_dir / "boot"
        if not boot_dir.exists():
            boot_dir = staging_dir  # Use entire staging as boot base

        def _progress_cb(pct: float, msg: str) -> None:
            # Scale USB builder progress to 40-95%
            job.progress = 40.0 + pct * 0.55
            self._log(job, f"  USB: {msg}")

        await self._usb_builder.build_usb_image(
            output_path=output_path,
            image_size=target_size,
            boot_files_dir=boot_dir,
            data_files_dir=data_dir,
            progress_callback=_progress_cb,
        )

        job.output_path = str(output_path)
        job.output_files = [str(output_path)]
        job.progress = 95.0

    async def _build_dvd(
        self,
        job: BuildJob,
        staging_dir: Path,
        image_files: list[tuple[str, Path]],
        build_dir: Path,
    ) -> None:
        """Build DVD ISO image(s), splitting across multiple discs if needed."""
        self._log(job, "Building DVD image(s)")

        def _progress_cb(pct: float, msg: str) -> None:
            job.progress = 15.0 + pct * 0.80
            self._log(job, f"  DVD: {msg}")

        iso_files = await self._dvd_splitter.split_and_build(
            output_dir=build_dir,
            base_files_dir=staging_dir,
            image_files=image_files,
            progress_callback=_progress_cb,
        )

        job.output_files = [str(p) for p in iso_files]
        if iso_files:
            job.output_path = str(iso_files[0])
        job.progress = 95.0

        self._log(job, f"Created {len(iso_files)} DVD ISO(s)")

    async def _build_data(
        self,
        job: BuildJob,
        staging_dir: Path,
        image_files: list[tuple[str, Path]],
        build_dir: Path,
    ) -> None:
        """Build a data-only ISO (no boot, just BareIgnite + images)."""
        self._log(job, "Building data ISO")

        # Copy images to staging
        images_dest = staging_dir / "images"
        images_dest.mkdir(parents=True, exist_ok=True)

        for label, src_path in image_files:
            self._log(job, f"  Copying {label}")
            dest = images_dest / src_path.name
            await asyncio.to_thread(shutil.copy2, str(src_path), str(dest))

        job.progress = 50.0

        output_path = build_dir / "bareignite_data.iso"

        def _progress_cb(pct: float, msg: str) -> None:
            job.progress = 50.0 + pct * 0.45
            self._log(job, f"  ISO: {msg}")

        await self._iso_builder.build_data_iso(
            output_path=output_path,
            source_dir=staging_dir,
            volume_label="BAREIGNITE_DATA",
            progress_callback=_progress_cb,
        )

        job.output_path = str(output_path)
        job.output_files = [str(output_path)]
        job.progress = 95.0

    async def _prepare_base_files(self, staging_dir: Path) -> None:
        """Copy BareIgnite base files into the staging directory.

        Includes scripts, templates, configs, PXE files, and tools.
        """
        bareignite_root = settings.bareignite_root

        # Directories to include in the base
        base_dirs = {
            "scripts": bareignite_root / "scripts",
            "templates": bareignite_root / "templates",
            "conf": bareignite_root / "conf",
            "pxe": bareignite_root / "pxe",
            "tools": bareignite_root / "tools",
            "ansible": bareignite_root / "ansible",
        }

        # Copy each directory if it exists
        for dest_name, src_path in base_dirs.items():
            if src_path.exists() and src_path.is_dir():
                dest_path = staging_dir / dest_name
                await asyncio.to_thread(
                    shutil.copytree, str(src_path), str(dest_path), dirs_exist_ok=True
                )

        # Copy bareignite.sh entry point
        entry_script = bareignite_root / "bareignite.sh"
        if entry_script.exists():
            await asyncio.to_thread(
                shutil.copy2, str(entry_script), str(staging_dir / "bareignite.sh")
            )

        # Copy VERSION
        version_file = bareignite_root / "VERSION"
        if version_file.exists():
            await asyncio.to_thread(
                shutil.copy2, str(version_file), str(staging_dir / "VERSION")
            )

    def _find_cached_image(self, os_id: str, arch: str) -> Optional[object]:
        """Find a cached image matching the given OS ID and architecture.

        Tries multiple ID formats:
            - exact match: os_id
            - with arch: os_id-*-arch
        """
        cached = image_manager.get_cached_images()

        # Exact ID match
        for img in cached:
            if img.id == os_id:
                return img

        # Try os_id-version-arch pattern
        for img in cached:
            if img.id.startswith(f"{os_id}-") and img.arch == arch:
                return img

        # Try matching by name/family prefix
        for img in cached:
            if os_id in img.id and img.arch == arch:
                return img

        return None

    def cancel_build(self, build_id: str) -> bool:
        """Cancel a running build job.

        Returns:
            True if the build was cancelled
        """
        job = self._jobs.get(build_id)
        if not job:
            return False

        if job.status not in ("pending", "running"):
            return False

        task = self._tasks.get(build_id)
        if task and not task.done():
            task.cancel()

        job.status = "cancelled"
        job.error = "Cancelled by user"
        self._log(job, "Build cancelled by user")
        return True

    def get_build(self, build_id: str) -> Optional[BuildJob]:
        """Get a build job by ID."""
        return self._jobs.get(build_id)

    def list_builds(self) -> list[BuildJob]:
        """List all build jobs."""
        return list(self._jobs.values())

    def get_build_log(self, build_id: str) -> list[str]:
        """Get the log messages for a build job."""
        job = self._jobs.get(build_id)
        if not job:
            return []
        return job.log

    @staticmethod
    def _log(job: BuildJob, message: str) -> None:
        """Add a timestamped message to the build log."""
        timestamp = datetime.now().strftime("%H:%M:%S")
        entry = f"[{timestamp}] {message}"
        job.log.append(entry)
        logger.info("Build %s: %s", job.id, message)

    @staticmethod
    def _dir_size(path: Path) -> int:
        """Calculate total file size in a directory tree."""
        total = 0
        for item in path.rglob("*"):
            if item.is_file():
                total += item.stat().st_size
        return total


# Singleton instance
packager = Packager()
