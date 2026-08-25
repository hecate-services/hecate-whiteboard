# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [SemVer](https://semver.org/).

## [Unreleased]

### Added

- Walking skeleton: `hecate_whiteboard` (hecate_om_service, first Elixir
  implementation of that behaviour in this workspace) + `guide_board_lifecycle`
  CMD app (`initiate_board`, `archive_board`). Boots, joins the mesh,
  serves `/health`, dispatches both commands against a real reckon-db
  store with the business-rule guard enforced.
- Container image + CI (`build-push.yml`, `lint.yml`), deployed to
  `beam00.lab`/`beam01.lab` via macula-demo's pull-based reconciler.
