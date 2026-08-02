# Memory Card Test

A native macOS app to test your memory card speed and capacity, while detecting fakes.

Counterfeit SD cards and USB drives are common: they report a large capacity to the
operating system but contain far less real flash. Once you write past the real
capacity, the data is silently lost or overwritten. This app catches that by writing
a known pattern to the card and reading every byte back to confirm it was actually
stored.

Inspired by [F3 (Fight Flash Fraud)](https://fight-flash-fraud.readthedocs.io/) and
the no-longer-maintained F3X Swift GUI. The testing algorithm here is an independent
Swift implementation.

## Features

- **Auto-detects removable cards** (SD, USB) with capacity and free space, and will
  not casually offer your boot disk.
- **Quick speed test** — writes and verifies up to ~512 MB for a fast sequential
  read/write benchmark plus a basic integrity check.
- **Full capacity test** — fills essentially all free space, then reads every byte
  back. Slower, but the reliable way to confirm real capacity and catch fakes.
- Uses `F_NOCACHE` so read tests hit the physical card rather than the OS cache, and
  `F_FULLFSYNC` so write speeds are honest.
- Live progress with MB/s, cancel at any time, and automatic cleanup of test files.

## Requirements

- macOS 13 or later
- Swift 6 toolchain (Xcode or Command Line Tools) to build from source

## Building

```bash
./build.sh
```

This compiles a release build and wraps it into `Memory Card Test.app`, generating
the app icon from `icon.png`.

To produce the distributable zip (app + README + license):

```bash
./package.sh
```

## Installing the release build

The app is not signed with an Apple Developer certificate, so on first launch macOS
will say it "cannot be opened because Apple cannot check it for malicious software."
This is expected. To open it:

1. Right-click (or Control-click) **Memory Card Test.app** and choose **Open**.
2. Click **Open** in the dialog that appears.

You only need to do this once.

## Notes and limitations

- Testing is file-based and runs without administrator privileges, so it covers the
  card's **free space**. On an empty card — the case that matters when validating a
  new purchase — that is effectively the whole card.
- Speed figures are large-block sequential throughput (what "read/write speed" means
  on packaging), not random IOPS.
- Test data is written to a temporary folder on the card and deleted automatically
  when the test finishes or is stopped.

## Author

Created by Matt Johnson — [whoismatt.com](https://whoismatt.com)

## License

Released under the **GNU General Public License, version 3 (GPLv3)**. See
[LICENSE.txt](LICENSE.txt) for the full text, or
<https://www.gnu.org/licenses/gpl-3.0.html>.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.
