"""Pydantic models for OS image management."""

from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class OSImage(BaseModel):
    """Represents an OS image in the cache or registry."""

    id: str = Field(..., description="Unique identifier (e.g. rocky9-9.5-x86_64)")
    name: str = Field(..., description="Human-readable name")
    version: str = Field(..., description="OS version string")
    arch: str = Field(..., description="Architecture (x86_64, aarch64)")
    family: str = Field(..., description="OS family (rhel, debian, esxi, windows)")
    iso_path: Optional[str] = Field(None, description="Path to cached ISO file")
    size: int = Field(0, description="File size in bytes")
    sha256: str = Field("", description="SHA256 checksum of the ISO")
    download_url: Optional[str] = Field(None, description="URL to download the ISO")
    cached: bool = Field(False, description="Whether the image is cached locally")
    cache_date: Optional[datetime] = Field(
        None, description="When the image was cached"
    )
    note: Optional[str] = Field(None, description="Additional notes (e.g. manual download)")


class ImageList(BaseModel):
    """Response model for listing images."""

    images: list[OSImage] = Field(default_factory=list)
    total: int = Field(0, description="Total number of images")
    cached_count: int = Field(0, description="Number of cached images")


class DownloadRequest(BaseModel):
    """Request to download an OS image."""

    os_id: str = Field(..., description="OS identifier from registry (e.g. rocky9)")
    version: str = Field(..., description="Version string (e.g. 9.5)")
    arch: str = Field("x86_64", description="Architecture to download")


class DownloadProgress(BaseModel):
    """Progress information for an active download."""

    os_id: str
    status: str = Field("pending", description="pending|downloading|completed|failed|verifying")
    progress: float = Field(0.0, description="Download progress 0-100")
    downloaded_bytes: int = Field(0)
    total_bytes: int = Field(0)
    speed_bps: int = Field(0, description="Download speed in bytes per second")
    error: Optional[str] = None


class ImportRequest(BaseModel):
    """Request to import a local ISO file."""

    file_path: str = Field(..., description="Path to local ISO file to import")
    os_id: str = Field(..., description="OS identifier to assign")
    name: str = Field(..., description="Human-readable name")
    version: str = Field(..., description="OS version string")
    arch: str = Field("x86_64", description="Architecture")
    family: str = Field("rhel", description="OS family")
