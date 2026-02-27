"""Pydantic models for component version tracking and updates."""

from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class Component(BaseModel):
    """Represents a tracked software component."""

    name: str = Field(..., description="Component name")
    category: str = Field(
        ...,
        description="Category: os|pxe|tools|ansible|bareignite",
    )
    current_version: str = Field("", description="Currently installed/cached version")
    latest_version: str = Field("", description="Latest available version")
    update_available: bool = Field(
        False, description="Whether an update is available"
    )
    last_checked: Optional[datetime] = Field(
        None, description="Last time an update check was performed"
    )
    check_type: str = Field(
        "", description="How to check: github_release|url_pattern|pypi"
    )
    check_url: Optional[str] = Field(None, description="URL or repo for checking")
    repo: Optional[str] = Field(None, description="GitHub repo (owner/name)")
    package: Optional[str] = Field(None, description="PyPI package name")


class UpdateCheckResult(BaseModel):
    """Result of checking for component updates."""

    components: list[Component] = Field(default_factory=list)
    total: int = Field(0)
    updates_available: int = Field(0)
    checked_at: datetime = Field(default_factory=datetime.now)


class MediaDevice(BaseModel):
    """Represents a detected removable media device."""

    device: str = Field(..., description="Device path (e.g. /dev/sdb)")
    model: str = Field("", description="Device model name")
    size: int = Field(0, description="Device size in bytes")
    size_human: str = Field("", description="Human-readable size")
    vendor: str = Field("", description="Device vendor")
    removable: bool = Field(True, description="Whether the device is removable")
    mounted: bool = Field(False, description="Whether the device is mounted")
    mount_points: list[str] = Field(
        default_factory=list, description="Active mount points"
    )
    device_type: str = Field(
        "usb", description="Device type: usb|optical"
    )


class MediaWriteJob(BaseModel):
    """Represents a media write operation."""

    id: str = Field(..., description="Write job identifier")
    device: str = Field(..., description="Target device path")
    source_path: str = Field(..., description="Source image path")
    status: str = Field(
        "pending", description="Status: pending|writing|verifying|completed|failed"
    )
    progress: float = Field(0.0, description="Write progress 0-100")
    bytes_written: int = Field(0)
    total_bytes: int = Field(0)
    speed_bps: int = Field(0, description="Write speed in bytes per second")
    error: Optional[str] = None


class MediaWriteRequest(BaseModel):
    """Request to write an image to a media device."""

    build_id: str = Field(..., description="Build job ID whose output to write")
    device: str = Field(..., description="Target device path (e.g. /dev/sdb)")
    verify: bool = Field(True, description="Verify after writing")
