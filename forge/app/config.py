"""Application configuration loaded from environment variables."""

import os
from pathlib import Path


class Settings:
    """Central configuration for the Forge application."""

    def __init__(self) -> None:
        # Base directories
        self.cache_dir: Path = Path(
            os.environ.get("FORGE_CACHE_DIR", "/app/cache")
        )
        self.output_dir: Path = Path(
            os.environ.get("FORGE_OUTPUT_DIR", "/app/output")
        )
        self.data_dir: Path = Path(
            os.environ.get("FORGE_DATA_DIR", "/app/data")
        )
        self.builds_dir: Path = self.output_dir / "builds"

        # Sub-directories for cached content
        self.cache_os_dir: Path = self.cache_dir / "os"
        self.cache_pxe_dir: Path = self.cache_dir / "pxe"
        self.cache_tools_dir: Path = self.cache_dir / "tools"

        # Metadata file for tracking cached images
        self.metadata_file: Path = self.cache_dir / "metadata.json"

        # Download settings
        self.max_concurrent_downloads: int = int(
            os.environ.get("FORGE_MAX_DOWNLOADS", "3")
        )
        self.download_chunk_size: int = int(
            os.environ.get("FORGE_CHUNK_SIZE", str(8 * 1024 * 1024))  # 8MB
        )
        self.download_timeout: int = int(
            os.environ.get("FORGE_DOWNLOAD_TIMEOUT", "3600")  # 1 hour
        )

        # Media size constants (bytes)
        self.dvd_capacity: int = 4_700_000_000  # 4.7GB decimal (DVD-5)
        self.dvd_size: int = int(4.7 * 1024 * 1024 * 1024)  # 4.7GB binary
        self.usb_min_size: int = 8 * 1024 * 1024 * 1024  # 8GB minimum USB
        self.iso_overhead: int = 50 * 1024 * 1024  # 50MB overhead for ISO metadata

        # Operation chunk sizes
        self.io_chunk_size: int = 1 * 1024 * 1024  # 1MB for file I/O
        self.hash_chunk_size: int = 4 * 1024 * 1024  # 4MB for SHA256 hashing

        # Registry files
        self.os_registry_file: Path = self.data_dir / "os_registry.yaml"
        self.component_registry_file: Path = self.data_dir / "component_registry.yaml"

        # Ensure directories exist
        self._ensure_directories()

    def _ensure_directories(self) -> None:
        """Create required directories if they do not exist."""
        for directory in [
            self.cache_dir,
            self.output_dir,
            self.builds_dir,
            self.cache_os_dir,
            self.cache_pxe_dir,
            self.cache_tools_dir,
            self.data_dir,
        ]:
            directory.mkdir(parents=True, exist_ok=True)


# Singleton settings instance
settings = Settings()
