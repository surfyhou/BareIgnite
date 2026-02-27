"""Component update API endpoints."""

import logging
from typing import Optional

from fastapi import APIRouter, HTTPException, Query

from core.update_checker import update_checker
from models.component import Component, UpdateCheckResult

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/components", tags=["components"])


@router.get("", response_model=list[Component])
async def list_components(
    category: Optional[str] = Query(None, description="Filter by category"),
) -> list[Component]:
    """List all tracked components and their version status.

    Categories: os, pxe, tools, ansible, bareignite
    """
    components = update_checker.list_components()

    if category:
        components = [c for c in components if c.category == category]

    return components


@router.post("/check", response_model=UpdateCheckResult)
async def check_updates(
    category: Optional[str] = Query(
        None,
        description="Check only a specific category",
    ),
) -> UpdateCheckResult:
    """Trigger an update check for all or specific component categories.

    This contacts upstream sources (GitHub, PyPI, mirrors) to check for
    new versions. Can take several seconds to complete.
    """
    try:
        if category:
            if category == "os":
                results = await update_checker.check_os_updates()
            elif category == "pxe":
                results = await update_checker.check_pxe_updates()
            elif category == "tools":
                results = await update_checker.check_tool_updates()
            elif category == "ansible":
                results = await update_checker.check_ansible_updates()
            elif category == "bareignite":
                results = await update_checker.check_bareignite_updates()
            else:
                raise HTTPException(
                    status_code=400,
                    detail=f"Unknown category: {category}. "
                    f"Valid: os, pxe, tools, ansible, bareignite",
                )

            from datetime import datetime

            updates_count = sum(1 for c in results if c.update_available)
            return UpdateCheckResult(
                components=results,
                total=len(results),
                updates_available=updates_count,
                checked_at=datetime.now(),
            )
        else:
            return await update_checker.check_all()

    except Exception as e:
        logger.exception("Update check failed")
        raise HTTPException(
            status_code=500,
            detail=f"Update check failed: {str(e)}",
        )


@router.post("/update")
async def apply_updates(
    components: Optional[list[str]] = None,
) -> dict[str, object]:
    """Apply available updates for specified components.

    If no components are specified, applies all available updates.

    Note: This updates version tracking and downloads new binaries.
    For OS images, use the images API to pull updated versions.
    """
    try:
        updated = await update_checker.apply_updates(components)
        return {
            "status": "ok",
            "updated": updated,
            "count": len(updated),
        }
    except Exception as e:
        logger.exception("Update apply failed")
        raise HTTPException(
            status_code=500,
            detail=f"Failed to apply updates: {str(e)}",
        )
