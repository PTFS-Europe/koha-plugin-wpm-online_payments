# Changelog
All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- Correct version comparision to use internal perl version objects for dotted decimal version string comparisons
- Updated custom field regex to be more lenient with whitespace and plurals
- Map debit_type_codes for system types to allow backward compatability for WPM

## [v00.00.06] - 2020-08-20

### Fixed
- Add support for 19.11.x (accounttype -> debit_type_code)

## [v00.00.05] - 2019-09-06

### Added
- Configurable transaction level customfield definitions including basic template support
- Added the `interface` argument to the parameters passed in the call to Koha::Account::pay

## [v00.00.04] - 2019-08-09

### Fixed
- Remove $cgi->param called in list context warnings from configuration code
- Fixed typo in configurable VAT field keys

## [v00.00.03] - 2019-07-05

### Added
- Configurable VAT fields
- Configurable CustomField1

## [v00.00.02] - 2019-06-17

### Fixed
- Respect renewal rules.

## [v00.00.01] - 2019-06-14

Initial release

### Added
- Migrated logic from custom koha code into a plugin.
- Configuration screens
- Plugin methods for all basic actions


