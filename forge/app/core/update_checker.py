"""Component update checker for BareIgnite dependencies."""

import asyncio
import logging
import re
from datetime import datetime
from typing import Any, Optional

import aiohttp
import yaml

from config import settings
from models.component import Component, UpdateCheckResult

logger = logging.getLogger(__name__)

# Timeout for individual HTTP requests during update checks
CHECK_TIMEOUT = aiohttp.ClientTimeout(total=30)


class UpdateChecker:
    """Checks for updates to BareIgnite components and dependencies."""

    def __init__(self) -> None:
        self._components: dict[str, Component] = {}
        self._registry: dict[str, Any] = {}

    def initialize(self) -> None:
        """Load the component registry from YAML."""
        registry_path = settings.component_registry_file
        if not registry_path.exists():
            logger.warning("Component registry not found: %s", registry_path)
            return
        with open(registry_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}
        self._registry = data.get("components", {})

        # Build Component objects from registry
        for name, info in self._registry.items():
            self._components[name] = Component(
                name=name,
                category=info.get("category", ""),
                current_version=info.get("current_version", ""),
                check_type=info.get("check_type", ""),
                check_url=info.get("check_url"),
                repo=info.get("repo"),
                package=info.get("package"),
            )

        logger.info("UpdateChecker initialized: %d components", len(self._components))

    def list_components(self) -> list[Component]:
        """Return all tracked components."""
        return list(self._components.values())

    async def check_all(self) -> UpdateCheckResult:
        """Run update checks for all components concurrently."""
        tasks = []
        for name, component in self._components.items():
            tasks.append(self._check_component(name, component))

        results = await asyncio.gather(*tasks, return_exceptions=True)

        updated_components: list[Component] = []
        for result in results:
            if isinstance(result, Component):
                updated_components.append(result)
            elif isinstance(result, Exception):
                logger.error("Update check failed: %s", result)

        updates_count = sum(1 for c in updated_components if c.update_available)
        return UpdateCheckResult(
            components=updated_components,
            total=len(updated_components),
            updates_available=updates_count,
            checked_at=datetime.now(),
        )

    async def _check_component(self, name: str, component: Component) -> Component:
        """Check a single component for updates based on its check_type."""
        try:
            if component.check_type == "github_release":
                latest = await self._check_github_release(component.repo or "")
            elif component.check_type == "url_pattern":
                latest = await self._check_url_pattern(
                    component.check_url or "", name
                )
            elif component.check_type == "pypi":
                latest = await self._check_pypi(component.package or name)
            else:
                logger.debug("Unknown check_type '%s' for %s", component.check_type, name)
                latest = ""

            component.latest_version = latest
            component.last_checked = datetime.now()
            if latest and component.current_version:
                component.update_available = latest != component.current_version
            elif latest and not component.current_version:
                component.update_available = True
            else:
                component.update_available = False

        except Exception as e:
            logger.warning("Failed to check updates for %s: %s", name, e)
            component.last_checked = datetime.now()

        self._components[name] = component
        return component

    async def check_os_updates(self) -> list[Component]:
        """Check for new OS ISO versions by scraping mirror directories."""
        results: list[Component] = []
        os_registry_path = settings.os_registry_file
        if not os_registry_path.exists():
            return results

        with open(os_registry_path, "r", encoding="utf-8") as f:
            data = yaml.safe_load(f) or {}

        os_images = data.get("os_images", {})
        for os_key, os_info in os_images.items():
            check_url = os_info.get("check_url")
            if not check_url:
                continue
            versions = os_info.get("versions", {})
            current_latest = max(versions.keys()) if versions else ""

            try:
                new_version = await self._scrape_directory_version(
                    check_url, os_key
                )
                comp = Component(
                    name=os_key,
                    category="os",
                    current_version=str(current_latest),
                    latest_version=new_version,
                    update_available=(
                        bool(new_version) and new_version != str(current_latest)
                    ),
                    last_checked=datetime.now(),
                    check_type="url_pattern",
                    check_url=check_url,
                )
                results.append(comp)
            except Exception as e:
                logger.warning("Failed to check OS updates for %s: %s", os_key, e)

        return results

    async def check_pxe_updates(self) -> list[Component]:
        """Check syslinux, iPXE, GRUB for new releases."""
        pxe_components = [
            name
            for name, comp in self._components.items()
            if comp.category == "pxe"
        ]
        results: list[Component] = []
        for name in pxe_components:
            comp = self._components[name]
            updated = await self._check_component(name, comp)
            results.append(updated)
        return results

    async def check_tool_updates(self) -> list[Component]:
        """Check yq, jq and other tool GitHub releases."""
        tool_components = [
            name
            for name, comp in self._components.items()
            if comp.category == "tools"
        ]
        results: list[Component] = []
        for name in tool_components:
            comp = self._components[name]
            updated = await self._check_component(name, comp)
            results.append(updated)
        return results

    async def check_ansible_updates(self) -> list[Component]:
        """Check ansible-core and collections for updates."""
        ansible_components = [
            name
            for name, comp in self._components.items()
            if comp.category == "ansible"
        ]
        results: list[Component] = []
        for name in ansible_components:
            comp = self._components[name]
            updated = await self._check_component(name, comp)
            results.append(updated)
        return results

    async def check_bareignite_updates(self) -> list[Component]:
        """Check for BareIgnite repository updates."""
        bareignite_components = [
            name
            for name, comp in self._components.items()
            if comp.category == "bareignite"
        ]
        results: list[Component] = []
        for name in bareignite_components:
            comp = self._components[name]
            updated = await self._check_component(name, comp)
            results.append(updated)
        return results

    async def _check_github_release(self, repo: str) -> str:
        """Fetch the latest release tag from a GitHub repository.

        Args:
            repo: GitHub repository in 'owner/name' format

        Returns:
            The latest release tag name (e.g. 'v4.35.2')
        """
        if not repo:
            return ""
        url = f"https://api.github.com/repos/{repo}/releases/latest"
        async with aiohttp.ClientSession(timeout=CHECK_TIMEOUT) as session:
            headers = {"Accept": "application/vnd.github.v3+json"}
            async with session.get(url, headers=headers) as response:
                if response.status == 200:
                    data = await response.json()
                    tag = data.get("tag_name", "")
                    # Strip leading 'v' for normalized comparison
                    return tag.lstrip("v") if tag.startswith("v") else tag
                elif response.status == 404:
                    # Try tags endpoint as fallback (some repos don't use releases)
                    return await self._check_github_tags(repo, session)
                else:
                    logger.warning(
                        "GitHub API returned %d for %s", response.status, repo
                    )
                    return ""

    async def _check_github_tags(
        self, repo: str, session: aiohttp.ClientSession
    ) -> str:
        """Fallback: fetch latest tag from GitHub."""
        url = f"https://api.github.com/repos/{repo}/tags"
        async with session.get(
            url,
            headers={"Accept": "application/vnd.github.v3+json"},
            params={"per_page": "1"},
        ) as response:
            if response.status == 200:
                tags = await response.json()
                if tags:
                    tag = tags[0].get("name", "")
                    return tag.lstrip("v") if tag.startswith("v") else tag
            return ""

    async def _check_pypi(self, package: str) -> str:
        """Check PyPI for the latest version of a package.

        Args:
            package: PyPI package name

        Returns:
            The latest version string
        """
        if not package:
            return ""
        url = f"https://pypi.org/pypi/{package}/json"
        async with aiohttp.ClientSession(timeout=CHECK_TIMEOUT) as session:
            async with session.get(url) as response:
                if response.status == 200:
                    data = await response.json()
                    return data.get("info", {}).get("version", "")
                return ""

    async def _check_url_pattern(self, url: str, component_name: str) -> str:
        """Check a URL for version patterns (e.g. directory listing).

        Args:
            url: URL to fetch and parse
            component_name: Name of the component (for pattern matching)

        Returns:
            The latest version found
        """
        if not url:
            return ""
        return await self._scrape_directory_version(url, component_name)

    async def _scrape_directory_version(self, url: str, name: str) -> str:
        """Scrape a web directory listing for the latest version.

        Looks for version patterns in href attributes like:
        - syslinux-6.03/ or syslinux-6.03.tar.gz
        - Rocky-9.5-x86_64-dvd.iso
        """
        async with aiohttp.ClientSession(timeout=CHECK_TIMEOUT) as session:
            async with session.get(url) as response:
                if response.status != 200:
                    return ""
                html = await response.text()

        # Extract version-like patterns from the HTML
        # Match common version patterns in href links
        patterns = [
            # syslinux-6.03.tar.gz or name-version/
            rf'{re.escape(name)}[_-](\d+\.\d+(?:\.\d+)*)',
            # Generic version directory: 9.5/ or v4.35.2/
            r'href="v?(\d+\.\d+(?:\.\d+)*)/?["\s]',
        ]

        versions: list[str] = []
        for pattern in patterns:
            matches = re.findall(pattern, html, re.IGNORECASE)
            versions.extend(matches)

        if not versions:
            return ""

        # Sort versions and return the highest
        try:
            versions.sort(key=lambda v: [int(p) for p in v.split(".")])
            return versions[-1]
        except (ValueError, IndexError):
            return versions[-1] if versions else ""

    async def apply_updates(self, component_names: Optional[list[str]] = None) -> list[str]:
        """Apply available updates for specified components.

        This is a placeholder for actual update logic, which would need to:
        1. Download new versions of PXE/tools binaries
        2. Update configuration files
        3. Restart affected services

        Returns:
            List of component names that were updated
        """
        updated: list[str] = []
        targets = component_names or [
            name
            for name, comp in self._components.items()
            if comp.update_available
        ]

        for name in targets:
            comp = self._components.get(name)
            if not comp or not comp.update_available:
                continue

            logger.info(
                "Updating %s: %s -> %s",
                name,
                comp.current_version,
                comp.latest_version,
            )

            # For now, update the recorded version.
            # Real implementation would download and install the component.
            comp.current_version = comp.latest_version
            comp.update_available = False
            self._components[name] = comp
            updated.append(name)

        # Save updated registry back to YAML
        if updated:
            self._save_registry()

        return updated

    def _save_registry(self) -> None:
        """Write the component registry back to YAML with updated versions."""
        data: dict[str, Any] = {"components": {}}
        for name, comp in self._components.items():
            entry: dict[str, Any] = {
                "category": comp.category,
                "current_version": comp.current_version,
                "check_type": comp.check_type,
            }
            if comp.check_url:
                entry["check_url"] = comp.check_url
            if comp.repo:
                entry["repo"] = comp.repo
            if comp.package:
                entry["package"] = comp.package
            data["components"][name] = entry

        with open(settings.component_registry_file, "w", encoding="utf-8") as f:
            yaml.dump(data, f, default_flow_style=False, sort_keys=False)


# Singleton instance
update_checker = UpdateChecker()
