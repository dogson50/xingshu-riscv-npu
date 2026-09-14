# Changelog

All notable changes to this project will be documented in this file.

## [Unreleased]

### Changed

- Promoted S2-N1 native P4-striped full transport to the formal v13 RTL baseline.
- Replaced the centralized 512-bit result merge and large result FIFOs with four local P4 slices feeding resident PSUM islands.
- Added reproducible 64-bit full-transport regression and routed OOC PPA scripts/data.

### Added

- Initial open-source repository structure.
- Imported v13/A04 NPU RTL and self-checking regression tests.
- Architecture and PPA comparison artifacts.
- Collaboration, licensing and external dependency policies.