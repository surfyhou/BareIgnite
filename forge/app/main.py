"""BareIgnite Forge - Docker packaging service backend.

FastAPI application that provides APIs for:
- OS image management (download, import, cache)
- Build orchestration (USB, DVD, data ISO creation)
- Component update checking (PXE, tools, ansible)
- Removable media detection and writing
"""

import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import AsyncGenerator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from api.builds import router as builds_router
from api.components import router as components_router
from api.images import router as images_router
from api.media import router as media_router
from config import settings
from core.image_manager import image_manager
from core.update_checker import update_checker

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    """Application startup and shutdown events."""
    # Startup
    logger.info("BareIgnite Forge starting up")
    logger.info("Cache dir: %s", settings.cache_dir)
    logger.info("Output dir: %s", settings.output_dir)
    logger.info("Data dir: %s", settings.data_dir)

    # Initialize image manager (load cache metadata and OS registry)
    await image_manager.initialize()

    # Initialize update checker (load component registry)
    update_checker.initialize()

    logger.info("BareIgnite Forge is ready")
    yield

    # Shutdown
    logger.info("BareIgnite Forge shutting down")


# Create FastAPI application
app = FastAPI(
    title="BareIgnite Forge",
    description=(
        "Offline bare metal server provisioning media builder. "
        "Manages OS images, creates bootable USB/DVD media, "
        "and tracks component updates."
    ),
    version="0.1.0",
    lifespan=lifespan,
)

# CORS middleware - allow all origins for local development
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Mount API routers
app.include_router(images_router)
app.include_router(builds_router)
app.include_router(components_router)
app.include_router(media_router)

# Mount static files for Web UI (if directory exists and has files)
static_dir = Path(__file__).parent / "static"
if static_dir.exists() and any(static_dir.iterdir()):
    # Serve index.html at root
    @app.get("/", include_in_schema=False)
    async def serve_root():
        return FileResponse(str(static_dir / "index.html"))

    app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")
    logger.info("Static files mounted from %s", static_dir)


@app.get("/health", tags=["system"])
async def health_check() -> dict[str, str]:
    """Health check endpoint for container orchestration."""
    return {"status": "ok", "service": "bareignite-forge"}


@app.get("/api/status", tags=["system"])
async def system_status() -> dict[str, object]:
    """Get system status including cache and build information."""
    cached_images = image_manager.get_cached_images()
    total_cached_size = sum(img.size for img in cached_images)

    from core.packager import packager

    builds = packager.list_builds()
    active_builds = [b for b in builds if b.status in ("pending", "running")]

    return {
        "status": "ok",
        "version": "0.1.0",
        "cache": {
            "images_count": len(cached_images),
            "total_size": total_cached_size,
            "total_size_human": _format_size(total_cached_size),
            "cache_dir": str(settings.cache_dir),
        },
        "builds": {
            "total": len(builds),
            "active": len(active_builds),
            "output_dir": str(settings.output_dir),
        },
    }


def _format_size(size_bytes: int) -> str:
    """Format byte count to human-readable string."""
    if size_bytes == 0:
        return "0 B"
    units = ["B", "KB", "MB", "GB", "TB"]
    idx = 0
    size = float(size_bytes)
    while size >= 1024 and idx < len(units) - 1:
        size /= 1024
        idx += 1
    return f"{size:.1f} {units[idx]}"
