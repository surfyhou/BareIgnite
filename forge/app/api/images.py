"""Image management API endpoints."""

import logging
from typing import Optional

from fastapi import APIRouter, BackgroundTasks, HTTPException, Query

from core.image_manager import image_manager
from models.image import (
    DownloadProgress,
    DownloadRequest,
    ImageList,
    ImportRequest,
    OSImage,
)

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/images", tags=["images"])


@router.get("", response_model=ImageList)
async def list_images(
    cached_only: bool = Query(False, description="Only show cached images"),
    family: Optional[str] = Query(None, description="Filter by OS family"),
    arch: Optional[str] = Query(None, description="Filter by architecture"),
) -> ImageList:
    """List all known images from the registry, merged with cache status.

    Use query parameters to filter results.
    """
    images = image_manager.list_images()

    if cached_only:
        images = [img for img in images if img.cached]
    if family:
        images = [img for img in images if img.family == family]
    if arch:
        images = [img for img in images if img.arch == arch or img.arch == ""]

    cached_count = sum(1 for img in images if img.cached)
    return ImageList(images=images, total=len(images), cached_count=cached_count)


@router.post("/pull", response_model=DownloadProgress)
async def pull_image(
    request: DownloadRequest,
    background_tasks: BackgroundTasks,
) -> DownloadProgress:
    """Start downloading an OS image from the registry.

    The download runs in the background. Use the status endpoint to
    track progress.
    """
    # Check if already cached
    image_id = f"{request.os_id}-{request.version}-{request.arch}"
    existing = image_manager.get_image(image_id)
    if existing and existing.cached:
        return DownloadProgress(
            os_id=image_id,
            status="completed",
            progress=100.0,
            downloaded_bytes=existing.size,
            total_bytes=existing.size,
        )

    # Check if already downloading
    progress = image_manager.get_download_progress(image_id)
    if progress and progress.status == "downloading":
        return progress

    # Start background download
    try:
        image_manager.start_download_task(
            request.os_id, request.version, request.arch
        )
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    # Return initial progress
    progress = image_manager.get_download_progress(image_id)
    if progress:
        return progress

    return DownloadProgress(
        os_id=image_id,
        status="pending",
    )


@router.post("/import", response_model=OSImage)
async def import_image(request: ImportRequest) -> OSImage:
    """Import a local ISO file into the image cache.

    Use this for images that require manual download (ESXi, Windows, etc.)
    """
    try:
        image = await image_manager.import_image(
            file_path=request.file_path,
            os_id=request.os_id,
            name=request.name,
            version=request.version,
            arch=request.arch,
            family=request.family,
        )
        return image
    except FileNotFoundError as e:
        raise HTTPException(status_code=404, detail=str(e))
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.delete("/{image_id}")
async def delete_image(image_id: str) -> dict[str, str]:
    """Remove a cached image from the local cache."""
    deleted = await image_manager.delete_image(image_id)
    if not deleted:
        raise HTTPException(
            status_code=404,
            detail=f"Image not found: {image_id}",
        )
    return {"status": "deleted", "image_id": image_id}


@router.get("/{image_id}/status", response_model=DownloadProgress)
async def get_download_status(image_id: str) -> DownloadProgress:
    """Get the download progress for an image.

    Returns current status for active, completed, or failed downloads.
    """
    progress = image_manager.get_download_progress(image_id)
    if progress:
        return progress

    # Check if the image is already cached (completed earlier)
    image = image_manager.get_image(image_id)
    if image and image.cached:
        return DownloadProgress(
            os_id=image_id,
            status="completed",
            progress=100.0,
            downloaded_bytes=image.size,
            total_bytes=image.size,
        )

    raise HTTPException(
        status_code=404,
        detail=f"No download found for image: {image_id}",
    )


@router.get("/check-updates", response_model=list[OSImage])
async def check_image_updates() -> list[OSImage]:
    """Check for new versions of OS images in the registry.

    Compares cached versions against the latest available in the registry.
    """
    all_images = image_manager.list_images()
    updates: list[OSImage] = []

    # Group by OS family to find newer versions
    cached_by_os: dict[str, list[OSImage]] = {}
    for img in all_images:
        if img.cached:
            base_os = img.id.rsplit("-", 2)[0] if "-" in img.id else img.id
            if base_os not in cached_by_os:
                cached_by_os[base_os] = []
            cached_by_os[base_os].append(img)

    for img in all_images:
        if not img.cached:
            base_os = img.id.rsplit("-", 2)[0] if "-" in img.id else img.id
            if base_os in cached_by_os:
                # There is a cached version but this is a newer uncached version
                updates.append(img)

    return updates
