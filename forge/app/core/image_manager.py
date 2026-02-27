"""Image cache management for OS ISOs and related files."""

import asyncio
import hashlib
import json
import logging
import shutil
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Optional

import aiohttp
import yaml

from config import settings
from models.image import DownloadProgress, OSImage

logger = logging.getLogger(__name__)


class ImageManager:
    """Manages the local cache of OS images (ISOs)."""

    def __init__(self) -> None:
        self._cache: dict[str, OSImage] = {}
        self._downloads: dict[str, DownloadProgress] = {}
        self._download_tasks: dict[str, asyncio.Task[None]] = {}
        self._registry: dict[str, Any] = {}
        self._lock = asyncio.Lock()

    async def initialize(self) -> None:
        """Load cache metadata and OS registry on startup."""
        self.load_cache()
        self._load_registry()
        logger.info(
            "ImageManager initialized: %d cached images, %d registry entries",
            len([img for img in self._cache.values() if img.cached]),
            len(self._registry),
        )

    def _load_registry(self) -> None:
        """Load the OS registry from YAML file."""
        registry_path = settings.os_registry_file
        if not registry_path.exists():
            logger.warning("OS registry file not found: %s", registry_path)
            return
        with open(registry_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
        self._registry = data.get("os_images", {})

    def load_cache(self) -> None:
        """Read image metadata from cache/metadata.json."""
        if not settings.metadata_file.exists():
            self._cache = {}
            return
        try:
            with open(settings.metadata_file, "r", encoding="utf-8") as f:
                data = json.load(f)
            self._cache = {}
            for img_id, img_data in data.get("images", {}).items():
                self._cache[img_id] = OSImage(**img_data)
        except (json.JSONDecodeError, Exception) as e:
            logger.error("Failed to load cache metadata: %s", e)
            self._cache = {}

    def save_cache(self) -> None:
        """Write image metadata to cache/metadata.json."""
        data = {
            "images": {
                img_id: img.model_dump(mode="json")
                for img_id, img in self._cache.items()
            },
            "updated_at": datetime.now().isoformat(),
        }
        settings.metadata_file.parent.mkdir(parents=True, exist_ok=True)
        with open(settings.metadata_file, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2, default=str)

    def get_registry_images(self) -> list[OSImage]:
        """Build a list of all images from the registry, merged with cache status."""
        images: list[OSImage] = []
        for os_key, os_info in self._registry.items():
            versions = os_info.get("versions", {})
            note = os_info.get("note")
            if not versions and note:
                # OS with no downloadable versions (manual download required)
                img = OSImage(
                    id=os_key,
                    name=os_info.get("name", os_key),
                    version="",
                    arch="",
                    family=os_info.get("family", ""),
                    note=note,
                )
                # Check if manually imported
                if os_key in self._cache:
                    cached = self._cache[os_key]
                    img.cached = cached.cached
                    img.iso_path = cached.iso_path
                    img.size = cached.size
                    img.sha256 = cached.sha256
                    img.cache_date = cached.cache_date
                    img.version = cached.version
                    img.arch = cached.arch
                images.append(img)
                continue
            for ver, arches in versions.items():
                for arch, arch_info in arches.items():
                    image_id = f"{os_key}-{ver}-{arch}"
                    url = arch_info.get("url", "")
                    expected_sha256 = arch_info.get("sha256", "")
                    expected_size = arch_info.get("size", 0)

                    img = OSImage(
                        id=image_id,
                        name=os_info.get("name", os_key),
                        version=str(ver),
                        arch=arch,
                        family=os_info.get("family", ""),
                        download_url=url if url else None,
                        sha256=expected_sha256,
                        size=expected_size,
                        note=note,
                    )
                    # Merge with cached data
                    if image_id in self._cache:
                        cached = self._cache[image_id]
                        img.cached = cached.cached
                        img.iso_path = cached.iso_path
                        img.size = cached.size if cached.size else expected_size
                        img.sha256 = cached.sha256 if cached.sha256 else expected_sha256
                        img.cache_date = cached.cache_date
                    images.append(img)
        # Also include any cached images not in the registry (manually imported)
        for img_id, cached_img in self._cache.items():
            if not any(i.id == img_id for i in images):
                images.append(cached_img)
        return images

    def list_images(self) -> list[OSImage]:
        """List all known images (registry + cached)."""
        return self.get_registry_images()

    def get_image(self, image_id: str) -> Optional[OSImage]:
        """Get a specific image by ID."""
        for img in self.get_registry_images():
            if img.id == image_id:
                return img
        return self._cache.get(image_id)

    def get_cached_images(self) -> list[OSImage]:
        """Return only images that are locally cached."""
        return [img for img in self._cache.values() if img.cached]

    async def download_image(
        self,
        os_id: str,
        version: str,
        arch: str,
        progress_callback: Optional[Callable[[DownloadProgress], None]] = None,
    ) -> OSImage:
        """Download an OS image from the registry with progress tracking.

        Args:
            os_id: OS identifier from registry (e.g. 'rocky9')
            version: Version string (e.g. '9.5')
            arch: Architecture (e.g. 'x86_64')
            progress_callback: Optional callback for progress updates

        Returns:
            The cached OSImage

        Raises:
            ValueError: If the OS/version/arch is not found in registry
            RuntimeError: If download fails
        """
        image_id = f"{os_id}-{version}-{arch}"

        # Look up in registry
        os_info = self._registry.get(os_id)
        if not os_info:
            raise ValueError(f"OS '{os_id}' not found in registry")
        versions = os_info.get("versions", {})
        ver_info = versions.get(version) or versions.get(str(version))
        if not ver_info:
            raise ValueError(
                f"Version '{version}' not found for '{os_id}'. "
                f"Available: {list(versions.keys())}"
            )
        arch_info = ver_info.get(arch)
        if not arch_info:
            raise ValueError(
                f"Architecture '{arch}' not found for '{os_id}' {version}. "
                f"Available: {list(ver_info.keys())}"
            )

        url = arch_info.get("url", "")
        if not url:
            raise ValueError(
                f"No download URL for {os_id} {version} {arch}. "
                f"Note: {os_info.get('note', 'Manual download may be required.')}"
            )

        expected_sha256 = arch_info.get("sha256", "")
        expected_size = arch_info.get("size", 0)

        # Prepare cache directory and file path
        cache_subdir = settings.cache_os_dir / os_id
        cache_subdir.mkdir(parents=True, exist_ok=True)
        filename = url.rsplit("/", 1)[-1]
        iso_path = cache_subdir / filename

        # Initialize download progress
        progress = DownloadProgress(
            os_id=image_id,
            status="downloading",
            total_bytes=expected_size,
        )
        self._downloads[image_id] = progress

        try:
            start_time = time.time()
            timeout = aiohttp.ClientTimeout(total=settings.download_timeout)
            async with aiohttp.ClientSession(timeout=timeout) as session:
                async with session.get(url) as response:
                    if response.status != 200:
                        raise RuntimeError(
                            f"Download failed with HTTP {response.status}: {url}"
                        )
                    total = response.content_length or expected_size
                    progress.total_bytes = total

                    with open(iso_path, "wb") as f:
                        downloaded = 0
                        async for chunk in response.content.iter_chunked(
                            settings.download_chunk_size
                        ):
                            f.write(chunk)
                            downloaded += len(chunk)
                            elapsed = time.time() - start_time
                            progress.downloaded_bytes = downloaded
                            progress.progress = (
                                (downloaded / total * 100) if total > 0 else 0
                            )
                            progress.speed_bps = (
                                int(downloaded / elapsed) if elapsed > 0 else 0
                            )
                            if progress_callback:
                                progress_callback(progress)

            # Verify SHA256 if provided
            if expected_sha256:
                progress.status = "verifying"
                if progress_callback:
                    progress_callback(progress)
                actual_sha256 = await self._compute_sha256(iso_path)
                if actual_sha256 != expected_sha256:
                    iso_path.unlink(missing_ok=True)
                    raise RuntimeError(
                        f"SHA256 mismatch for {filename}: "
                        f"expected {expected_sha256}, got {actual_sha256}"
                    )
            else:
                # Compute SHA256 for our records
                actual_sha256 = await self._compute_sha256(iso_path)

            # Create the cached image record
            image = OSImage(
                id=image_id,
                name=os_info.get("name", os_id),
                version=str(version),
                arch=arch,
                family=os_info.get("family", ""),
                iso_path=str(iso_path),
                size=iso_path.stat().st_size,
                sha256=actual_sha256 if not expected_sha256 else expected_sha256,
                download_url=url,
                cached=True,
                cache_date=datetime.now(),
            )

            async with self._lock:
                self._cache[image_id] = image
                self.save_cache()

            progress.status = "completed"
            progress.progress = 100.0
            if progress_callback:
                progress_callback(progress)

            logger.info("Successfully downloaded and cached: %s", image_id)
            return image

        except Exception as e:
            progress.status = "failed"
            progress.error = str(e)
            if progress_callback:
                progress_callback(progress)
            logger.error("Download failed for %s: %s", image_id, e)
            raise

    async def import_image(
        self,
        file_path: str,
        os_id: str,
        name: str,
        version: str,
        arch: str,
        family: str,
    ) -> OSImage:
        """Import a local ISO file into the cache.

        Args:
            file_path: Path to the local ISO file
            os_id: OS identifier to assign
            name: Human-readable name
            version: OS version string
            arch: Architecture
            family: OS family

        Returns:
            The imported OSImage

        Raises:
            FileNotFoundError: If the source file doesn't exist
            ValueError: If the image ID is already cached
        """
        source = Path(file_path)
        if not source.exists():
            raise FileNotFoundError(f"File not found: {file_path}")

        image_id = f"{os_id}-{version}-{arch}" if version and arch else os_id

        # Prepare destination
        cache_subdir = settings.cache_os_dir / os_id
        cache_subdir.mkdir(parents=True, exist_ok=True)
        dest = cache_subdir / source.name

        # Copy file if not already in cache directory
        if source.resolve() != dest.resolve():
            logger.info("Copying %s to cache: %s", source, dest)
            await asyncio.to_thread(shutil.copy2, str(source), str(dest))
        else:
            logger.info("File already in cache directory: %s", dest)

        # Compute SHA256
        sha256 = await self._compute_sha256(dest)
        file_size = dest.stat().st_size

        image = OSImage(
            id=image_id,
            name=name,
            version=version,
            arch=arch,
            family=family,
            iso_path=str(dest),
            size=file_size,
            sha256=sha256,
            cached=True,
            cache_date=datetime.now(),
        )

        async with self._lock:
            self._cache[image_id] = image
            self.save_cache()

        logger.info("Imported image: %s (%d bytes, sha256=%s)", image_id, file_size, sha256)
        return image

    async def verify_image(self, image_id: str) -> bool:
        """Verify the SHA256 checksum of a cached image.

        Returns:
            True if verification passes, False otherwise
        """
        image = self._cache.get(image_id)
        if not image or not image.cached or not image.iso_path:
            raise ValueError(f"Image '{image_id}' is not cached")

        iso_path = Path(image.iso_path)
        if not iso_path.exists():
            logger.warning("Cached file missing: %s", iso_path)
            return False

        if not image.sha256:
            logger.warning("No SHA256 recorded for %s, skipping verification", image_id)
            return True

        actual = await self._compute_sha256(iso_path)
        matches = actual == image.sha256
        if not matches:
            logger.error(
                "SHA256 mismatch for %s: expected %s, got %s",
                image_id,
                image.sha256,
                actual,
            )
        return matches

    async def delete_image(self, image_id: str) -> bool:
        """Remove an image from the cache.

        Returns:
            True if the image was deleted
        """
        image = self._cache.get(image_id)
        if not image:
            return False

        if image.iso_path:
            iso_path = Path(image.iso_path)
            if iso_path.exists():
                iso_path.unlink()
                logger.info("Deleted cached file: %s", iso_path)
                # Remove parent dir if empty
                parent = iso_path.parent
                if parent != settings.cache_os_dir and not any(parent.iterdir()):
                    parent.rmdir()

        async with self._lock:
            del self._cache[image_id]
            self.save_cache()

        logger.info("Removed image from cache: %s", image_id)
        return True

    def get_download_progress(self, image_id: str) -> Optional[DownloadProgress]:
        """Get the download progress for an image."""
        return self._downloads.get(image_id)

    def start_download_task(
        self, os_id: str, version: str, arch: str
    ) -> str:
        """Start a background download task.

        Returns:
            The image ID for tracking
        """
        image_id = f"{os_id}-{version}-{arch}"

        if image_id in self._download_tasks:
            task = self._download_tasks[image_id]
            if not task.done():
                return image_id  # Already downloading

        async def _run_download() -> None:
            try:
                await self.download_image(os_id, version, arch)
            except Exception as e:
                logger.error("Background download failed for %s: %s", image_id, e)

        task = asyncio.create_task(_run_download())
        self._download_tasks[image_id] = task
        return image_id

    async def _compute_sha256(self, path: Path) -> str:
        """Compute SHA256 hash of a file asynchronously."""

        def _hash_file() -> str:
            sha256 = hashlib.sha256()
            with open(path, "rb") as f:
                while True:
                    chunk = f.read(settings.hash_chunk_size)
                    if not chunk:
                        break
                    sha256.update(chunk)
            return sha256.hexdigest()

        return await asyncio.to_thread(_hash_file)


# Singleton instance
image_manager = ImageManager()
