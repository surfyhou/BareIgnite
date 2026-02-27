"""Build/packaging API endpoints."""

import logging
from typing import Optional

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import StreamingResponse

from core.packager import packager
from models.build_job import BuildJob, BuildList, BuildRequest

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/builds", tags=["builds"])


@router.post("", response_model=BuildJob)
async def create_build(request: BuildRequest) -> BuildJob:
    """Create a new build job.

    Starts building the specified media type with the requested OS images.
    The build runs in the background. Use the status endpoint to track progress.

    Media types:
        - usb: Creates a bootable USB disk image (.img)
        - dvd: Creates bootable DVD ISO(s), splitting if needed
        - data: Creates a data-only ISO with BareIgnite + images
    """
    # Validate media type
    if request.media_type not in ("usb", "dvd", "data"):
        raise HTTPException(
            status_code=400,
            detail=f"Invalid media_type '{request.media_type}'. "
            f"Must be one of: usb, dvd, data",
        )

    if not request.os_list:
        raise HTTPException(
            status_code=400,
            detail="os_list must not be empty",
        )

    try:
        job = packager.create_build(request)
        return job
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))


@router.get("", response_model=BuildList)
async def list_builds(
    status: Optional[str] = Query(None, description="Filter by status"),
) -> BuildList:
    """List all build jobs, optionally filtered by status."""
    builds = packager.list_builds()

    if status:
        builds = [b for b in builds if b.status == status]

    return BuildList(builds=builds, total=len(builds))


@router.get("/{build_id}", response_model=BuildJob)
async def get_build(build_id: str) -> BuildJob:
    """Get the status and details of a specific build job."""
    job = packager.get_build(build_id)
    if not job:
        raise HTTPException(
            status_code=404,
            detail=f"Build not found: {build_id}",
        )
    return job


@router.delete("/{build_id}")
async def cancel_build(build_id: str) -> dict[str, str]:
    """Cancel a running or pending build job."""
    cancelled = packager.cancel_build(build_id)
    if not cancelled:
        job = packager.get_build(build_id)
        if not job:
            raise HTTPException(
                status_code=404,
                detail=f"Build not found: {build_id}",
            )
        raise HTTPException(
            status_code=400,
            detail=f"Cannot cancel build in state: {job.status}",
        )
    return {"status": "cancelled", "build_id": build_id}


@router.get("/{build_id}/log")
async def get_build_log(
    build_id: str,
    stream: bool = Query(False, description="Stream log in real-time via SSE"),
) -> dict[str, object]:
    """Get the build log for a specific job.

    If stream=true, returns a Server-Sent Events stream for real-time log updates.
    Otherwise, returns the current log as a JSON array.
    """
    job = packager.get_build(build_id)
    if not job:
        raise HTTPException(
            status_code=404,
            detail=f"Build not found: {build_id}",
        )

    if stream:
        return StreamingResponse(
            _stream_log(build_id),
            media_type="text/event-stream",
        )

    log = packager.get_build_log(build_id)
    return {
        "build_id": build_id,
        "status": job.status,
        "progress": job.progress,
        "log": log,
    }


async def _stream_log(build_id: str):
    """Generator for SSE log streaming.

    Yields new log lines as they appear, ending when the build completes.
    """
    import asyncio

    last_idx = 0
    while True:
        job = packager.get_build(build_id)
        if not job:
            yield f"event: error\ndata: Build not found\n\n"
            break

        log = job.log
        if len(log) > last_idx:
            for line in log[last_idx:]:
                yield f"data: {line}\n\n"
            last_idx = len(log)

        if job.status in ("completed", "failed", "cancelled"):
            yield f"event: done\ndata: {job.status}\n\n"
            break

        await asyncio.sleep(1)
