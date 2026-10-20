# Third-party notices

The original code and documentation are MIT licensed (LICENSE). Image rights
are separate (ASSET_LICENSES.md), including the unlicensed Bonobono fan images.

## macOS

The Swift/AppKit app uses macOS system frameworks. These are provided by the
operating system and are not redistributed in the ZIP. Swift runtime support
is supplied by macOS 13 or later. No third-party package is linked into the app.

## Windows

The portable folder includes unmodified, dynamically loaded Qt/PySide6 and
Shiboken6 6.10.2, Pillow 12.0.0, a Python runtime, and a PyInstaller bootloader.
The build uses PySide6-Essentials; it does not install Qt Addons. Individual
components retain their own licenses, copyright and attribution notices.
Installed packages' license files are copied into `licenses/` in the ZIP;
Python's license is also retained alongside its runtime. See
`THIRD_PARTY_NOTICES.txt` in the Windows folder and `BUILD-INFO.json` for versions.

- Qt / PySide6 / Shiboken6: LGPL-3.0 (with applicable Qt exceptions), GPL or
  commercial alternatives as specified in the bundled notices. This project
  uses the LGPL option for the dynamically linked LGPL components.
- Pillow: MIT-CMU and the individual notices supplied with the package.
- Python: PSF and the third-party notices shipped in its LICENSE file.
- PyInstaller: GPL with the bootloader distribution exception. This exception
  permits distributing the application under its own license.

The application does not prohibit reverse engineering for debugging changes
to LGPL components. Libraries remain separate in `_internal` and can be
replaced with compatible modified builds; keep ABI, Python version and module
names compatible. This is a portable application with no activation or
signature check preventing that replacement. Rebuild instructions and exact
upstream source locations are in `docs/RELEASING.md` and `SOURCE-CODE.txt` in
the Windows distribution.

Upstream projects:

- https://code.qt.io/cgit/pyside/pyside-setup.git/ (tag v6.10.2)
- https://download.qt.io/archive/qt/6.10/6.10.2/submodules/
- https://github.com/python-pillow/Pillow/tree/12.0.0
- https://github.com/python/cpython
- https://github.com/pyinstaller/pyinstaller/tree/v6.22.3

No license for a library grants rights to the character images.
