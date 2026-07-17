# Vendored `unorm_dart` Unicode 15.1 tables

This is the MIT-licensed `unorm_dart` normalization implementation from
`https://github.com/yshrsmz/unorm-dart`, with only its generated normalization
data replaced for Archivale's pinned Unicode 15.1 group-name identity contract.

## Provenance and regeneration

- Unicode version: **15.1.0**.
- Source data: `UnicodeData.txt` and `CompositionExclusions.txt` from
  `https://www.unicode.org/Public/15.1.0/ucd/`.
- Generator: the vendored `tools/normalizer_gen.dart` from the upstream
  implementation.
- Generated output: `lib/src/unormdata.dart`.

The downloaded Unicode 15.1 source checksums used for this vendored table are:

- `UnicodeData.txt`: `2fc713e6a31a87c4850a37fe2caffa4218180fadb5de86b43a143ddb4581fb86`
- `CompositionExclusions.txt`: `59d2d9e3dfdf0a999cf9dae11d594f053631222679a2f5710315ea07f7fe82af`
- `CaseFolding.txt`: `4e55acfdc32825a22e87670e9056a3bf94ad7c5400065778e9e10f8314372bcf`
- `DerivedCoreProperties.txt`: `f55d0db69123431a7317868725b1fcbf1eab6b265d756d1bd7f0f6d9f9ee108b`

The app's full default case-fold table is generated separately from Unicode
15.1 `CaseFolding.txt` and is kept beside the group-name code at
`lib/app/storage/unicode_15_1_casefold.dart`.
