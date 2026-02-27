"""Pydantic models for build jobs."""

from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class BuildJob(BaseModel):
    """Represents a build/packaging job."""

    id: str = Field(..., description="Unique build job identifier")
    status: str = Field(
        "pending",
        description="Job status: pending|running|completed|failed|cancelled",
    )
    os_list: list[str] = Field(
        ..., description="List of OS image IDs to include"
    )
    arch_list: list[str] = Field(
        default_factory=lambda: ["x86_64"],
        description="Target architectures",
    )
    media_type: str = Field(
        "usb", description="Output media type: usb|dvd|data"
    )
    target_size: Optional[int] = Field(
        None, description="Target media size in bytes (auto-detected if None)"
    )
    created_at: datetime = Field(
        default_factory=datetime.now, description="Job creation timestamp"
    )
    completed_at: Optional[datetime] = Field(
        None, description="Job completion timestamp"
    )
    output_path: Optional[str] = Field(
        None, description="Path to output file(s)"
    )
    output_files: list[str] = Field(
        default_factory=list, description="List of output file paths (for multi-disc)"
    )
    progress: float = Field(0.0, description="Build progress 0-100")
    log: list[str] = Field(
        default_factory=list, description="Build log messages"
    )
    total_size: int = Field(0, description="Total size of included images in bytes")
    error: Optional[str] = Field(None, description="Error message if failed")


class BuildRequest(BaseModel):
    """Request to create a new build job."""

    os_list: list[str] = Field(
        ..., description="List of OS image IDs to include"
    )
    arch_list: list[str] = Field(
        default_factory=lambda: ["x86_64"],
        description="Target architectures",
    )
    media_type: str = Field(
        "usb", description="Output media type: usb|dvd|data"
    )
    target_size: Optional[int] = Field(
        None, description="Target media size in bytes"
    )


class BuildList(BaseModel):
    """Response model for listing builds."""

    builds: list[BuildJob] = Field(default_factory=list)
    total: int = Field(0)
