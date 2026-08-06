# Image size audit

## Scope

This audit measures `nix build .#oci-image` on `x86_64-linux`.
The source commit is `cd1638c29d02a035e349412d1e53e197f2845e78`.
The locked Nixpkgs revision is
`b7c2ada94fe99c15b0dbcf4d11fd7850b957a436`.

All sizes in MiB use 1,048,576 bytes.

## Result

The image has no wasted layer data. The main size source is the full set of
Tesseract language models. An English-only test image reduced the archive from
738.2 MiB to 278.4 MiB.

| Measurement            | Current image | English-only test image |         Reduction |
| ---------------------- | ------------: | ----------------------: | ----------------: |
| Compressed archive     |     738.2 MiB |               278.4 MiB | 459.7 MiB (62.3%) |
| Dive filesystem size   |   1,750.7 MiB |               758.2 MiB | 992.4 MiB (56.7%) |
| Layer count            |            98 |                      98 |                 0 |
| Dive efficiency score  |           1.0 |                     1.0 |               n/a |
| Dive inefficient bytes |             0 |                       0 |                 0 |

The exact compressed archive sizes were 774,019,849 bytes and 291,947,279
bytes.

## Tesseract language data

The default `pkgs.tesseract` package installs all available language models.
The image therefore contains 129 trained models. Their Nix store path is about
1,015 MiB before compression. Its layer is about 468 MiB after separate gzip
compression.

The acceptance OCR script uses the default English model. The English model is
23 MiB before compression and 10.4 MiB after separate gzip compression.

The change must cover both Tesseract references:

1. Override `pkgs.tesseract` with `enableLanguages = [ "eng" ];`.
2. Override `pythonPackages.pytesseract` with the same Tesseract package.

Nixpkgs patches `pytesseract` with the exact Tesseract store path. A change to
only the direct runtime package leaves the full language set in the Python
closure.

The measured test expression used this form:

```nix
let
  tesseract = pkgs.tesseract.override {
    enableLanguages = [ "eng" ];
  };

  python = pkgs.python3.withPackages (pythonPackages: [
    pythonPackages.matplotlib
    pythonPackages.numpy
    pythonPackages.openpyxl
    pythonPackages.orjson
    pythonPackages.pandas
    pythonPackages.pillow
    ((pythonPackages.pytesseract.override { inherit tesseract; }).overridePythonAttrs (old: {
      disabledTests = (old.disabledTests or [ ]) ++ [
        "test_get_languages"
        "test_image_to_osd"
        "test_image_to_string_european"
      ];
    }))
    pythonPackages.requests
  ]);
in
{
  agentRuntimePackages = [
    agent
    pkgs.cacert
    tesseract
    python
  ];
}
```

The three disabled upstream tests require French or orientation model data.
All other `pytesseract` package tests ran. The audit also verified these items:

- All eight declared Python libraries imported successfully.
- `pytesseract.get_languages()` returned only `eng`.
- `ocr_demo.py` read `THE QUICK BROWN FOX` correctly.

The English-only change removes support for other OCR languages and orientation
detection. The current acceptance scripts do not require these features.

## Remaining compressed size

The following values come from separate gzip compression of each image layer.
The layer values total 276.3 MiB. The complete archive is 278.4 MiB because its
metadata and compression layout add about 2.1 MiB.

| Layer content                               | Compressed size | Archive share |
| ------------------------------------------- | --------------: | ------------: |
| CPython 3.14 and mailcap                    |        64.9 MiB |         23.3% |
| Pandas                                      |        26.4 MiB |          9.5% |
| BLAS                                        |        23.3 MiB |          8.4% |
| LAPACK                                      |        23.3 MiB |          8.4% |
| Matplotlib and Cycler                       |        14.9 MiB |          5.4% |
| NumPy and related build support             |        14.5 MiB |          5.2% |
| OpenBLAS                                    |        11.7 MiB |          4.2% |
| glibc and the GCC support library           |        11.5 MiB |          4.1% |
| English Tesseract model                     |        10.4 MiB |          3.7% |
| GLib                                        |         5.0 MiB |          1.8% |
| Fortran runtime                             |         4.7 MiB |          1.7% |
| FontTools                                   |         4.3 MiB |          1.5% |
| `agent-sandbox`                             |         3.6 MiB |          1.3% |
| GCC runtime                                 |         3.5 MiB |          1.3% |
| ImageQuant                                  |         3.3 MiB |          1.2% |
| Remaining layers                            |        51.1 MiB |         18.4% |
| Archive metadata and compression difference |         2.1 MiB |          0.7% |

The first seven entries use about 65% of the archive. The Rust service itself
uses only 3.6 MiB after compression. Most of the remaining size belongs to the
Python scientific stack.

BLAS, LAPACK, OpenBLAS, and the Fortran runtime use about 63 MiB after
compression. NumPy, Pandas, and Matplotlib require this stack. Removing the
explicit NumPy entry does not remove it from the closure.

## Further package trimming

Two package changes can remove more runtime files without removing a declared
Python library.

| Content                                   | Size before compression | Separate gzip estimate |
| ----------------------------------------- | ----------------------: | ---------------------: |
| Static archives, mainly `libpython3.14.a` |                63.4 MiB |               42.6 MiB |
| Python package test trees                 |                83.5 MiB |               24.2 MiB |
| Combined maximum estimate                 |               146.9 MiB |               66.8 MiB |

The 66.8 MiB value is the maximum estimate for these two changes. It is not the
absolute minimum image size. If the compression ratio stays the same, these
changes can reduce the 278.4 MiB test image to about 211.7 MiB. A new build must
confirm the result.

Use `stripConfig = true` in a custom CPython package to remove the Python static
library and build configuration. Remove test directories with explicit Python
package overrides. Both changes require rebuilt Python packages and full image
tests.

The image also contains about 161 MiB of Python bytecode. It is about 56 MiB
after separate gzip compression, but this value overlaps the test-tree value.
Do not remove bytecode by default. Nixpkgs keeps it to prevent a large Python
startup cost. The read-only Nix store also prevents Python from writing a new
cache in place.

Further large reductions require a different BLAS provider or a different
Python package layout. These changes can affect performance, portability, and
maintenance. They are not simple package trimming.

## Dive procedure

Dive cannot read the outer gzip stream from this Nix image archive directly.
Decompress the archive before the audit:

```console
image=$(nix build --no-link --print-out-paths .#oci-image)
gzip -dc "$image" > /tmp/agent-sandbox-image.tar
nix run nixpkgs#dive -- \
  /tmp/agent-sandbox-image.tar \
  --source docker-archive \
  --json /tmp/agent-sandbox-dive.json
```

Dive reported an efficiency score of 1.0 and zero inefficient bytes. Layer
squashing and a different `maxLayers` value will not reduce the filesystem
content.
