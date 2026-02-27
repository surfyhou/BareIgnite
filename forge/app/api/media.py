"""Media output API endpoints for detecting devices and writing images."""

import asyncio
import logging
import uuid
from pathlib import Path
from typing import Optional

from fastapi import APIRouter, HTTPException

from core.media_detector import MediaDetector
from core.packager import packager
from models.component import MediaDevice, MediaWriteJob, MediaWriteRequest

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/media", tags=["media"])

# Singleton detector and write job tracking
_detector = MediaDetector()
_write_jobs: dict[str, MediaWriteJob] = {}
_write_tasks: dict[str, asyncio.Task[None]] = {}


@router.get("/devices", response_model=list[MediaDevice])
async def list_devices(
    device_type: Optional[str] = None,
) -> list[MediaDevice]:
    """Detect connected removable media devices.

    Returns USB drives and optical (DVD/BD) writers.
    Use device_type='usb' or 'optical' to filter.
    """
    devices: list[MediaDevice] = []

    if device_type is None or device_type == "usb":
        usb_devices = await _detector.detect_usb_devices()
        devices.extend(usb_devices)

    if device_type is None or device_type == "optical":
        optical_devices = await _detector.detect_optical_drives()
        devices.extend(optical_devices)

    return devices


@router.post("/write", response_model=MediaWriteJob)
async def write_to_device(request: MediaWriteRequest) -> MediaWriteJob:
    """Write a build output image to a removable media device.

    WARNING: This will ERASE ALL DATA on the target device.

    The write operation runs in the background. Use the status endpoint
    to track progress.
    """
    # Validate the build exists and has output
    build = packager.get_build(request.build_id)
    if not build:
        raise HTTPException(
            status_code=404,
            detail=f"Build not found: {request.build_id}",
        )
    if build.status != "completed":
        raise HTTPException(
            status_code=400,
            detail=f"Build is not completed (status: {build.status})",
        )
    if not build.output_path:
        raise HTTPException(
            status_code=400,
            detail="Build has no output file",
        )

    source_path = Path(build.output_path)
    if not source_path.exists():
        raise HTTPException(
            status_code=404,
            detail=f"Build output file not found: {build.output_path}",
        )

    # Validate device exists and is not mounted
    device_info = await _detector.get_device_info(request.device)
    if not device_info:
        raise HTTPException(
            status_code=404,
            detail=f"Device not found: {request.device}",
        )
    if device_info.mounted:
        raise HTTPException(
            status_code=400,
            detail=f"Device {request.device} is mounted at: "
            f"{', '.join(device_info.mount_points)}. Unmount first.",
        )

    # Check device is large enough
    if device_info.size > 0 and source_path.stat().st_size > device_info.size:
        raise HTTPException(
            status_code=400,
            detail=f"Image ({source_path.stat().st_size} bytes) is larger than "
            f"device ({device_info.size} bytes)",
        )

    # Create write job
    job_id = str(uuid.uuid4())[:8]
    job = MediaWriteJob(
        id=job_id,
        device=request.device,
        source_path=str(source_path),
        status="pending",
        total_bytes=source_path.stat().st_size,
    )
    _write_jobs[job_id] = job

    # Start background write task
    task = asyncio.create_task(
        _execute_write(job_id, source_path, request.device, request.verify)
    )
    _write_tasks[job_id] = task

    return job


@router.get("/write/{job_id}/status", response_model=MediaWriteJob)
async def get_write_status(job_id: str) -> MediaWriteJob:
    """Get the progress of a media write operation."""
    job = _write_jobs.get(job_id)
    if not job:
        raise HTTPException(
            status_code=404,
            detail=f"Write job not found: {job_id}",
        )
    return job


async def _execute_write(
    job_id: str,
    source_path: Path,
    device: str,
    verify: bool,
) -> None:
    """Execute the actual write operation using dd.

    Args:
        job_id: Write job ID for tracking
        source_path: Path to the image file
        device: Target device path (e.g. /dev/sdb)
        verify: Whether to verify after writing
    """
    job = _write_jobs[job_id]

    try:
        job.status = "writing"
        total_bytes = source_path.stat().st_size
        job.total_bytes = total_bytes

        # Use dd with progress reporting
        # dd writes from source to device with 4M block size
        block_size = 4 * 1024 * 1024  # 4MB
        cmd = [
            "dd",
            f"if={source_path}",
            f"of={device}",
            f"bs={block_size}",
            "conv=fsync",
            "status=progress",
        ]

        logger.info("Writing %s to %s (%d bytes)", source_path, device, total_bytes)

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        # dd reports progress on stderr
        import time

        start_time = time.time()

        # Read stderr for progress
        # dd status=progress outputs to stderr like: "1234567890 bytes transferred"
        while True:
            line = await process.stderr.readline()  # type: ignore[union-attr]
            if not line:
                break

            text = line.decode("utf-8", errors="replace").strip()
            if "bytes" in text:
                # Parse bytes written from dd output
                try:
                    parts = text.split()
                    bytes_written = int(parts[0])
                    job.bytes_written = bytes_written
                    job.progress = (bytes_written / total_bytes * 100) if total_bytes > 0 else 0
                    elapsed = time.time() - start_time
                    job.speed_bps = int(bytes_written / elapsed) if elapsed > 0 else 0
                except (ValueError, IndexError):
                    pass

        await process.wait()

        if process.returncode != 0:
            stderr_rest = await process.stderr.read() if process.stderr else b""  # type: ignore[union-attr]
            raise RuntimeError(
                f"dd failed (exit {process.returncode}): "
                f"{stderr_rest.decode('utf-8', errors='replace')}"
            )

        job.bytes_written = total_bytes
        job.progress = 100.0

        # Sync filesystem
        sync_proc = await asyncio.create_subprocess_exec(
            "sync",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        await sync_proc.communicate()

        # Optional verification
        if verify:
            job.status = "verifying"
            logger.info("Verifying write to %s", device)

            import hashlib

            # Hash the source file
            source_hash = hashlib.sha256()
            with open(source_path, "rb") as f:
                while True:
                    chunk = f.read(block_size)
                    if not chunk:
                        break
                    source_hash.update(chunk)

            # Hash the same number of bytes from the device
            device_hash = hashlib.sha256()
            bytes_read = 0
            with open(device, "rb") as f:
                while bytes_read < total_bytes:
                    to_read = min(block_size, total_bytes - bytes_read)
                    chunk = f.read(to_read)
                    if not chunk:
                        break
                    device_hash.update(chunk)
                    bytes_read += len(chunk)

            if source_hash.hexdigest() != device_hash.hexdigest():
                raise RuntimeError(
                    "Verification failed: written data does not match source"
                )

            logger.info("Verification passed for %s", device)

        job.status = "completed"
        logger.info("Write completed: %s -> %s", source_path, device)

    except Exception as e:
        job.status = "failed"
        job.error = str(e)
        logger.error("Write failed for job %s: %s", job_id, e)
