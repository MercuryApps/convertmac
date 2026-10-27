# Third-party software

The downloadable app includes a copy of FFmpeg built from unmodified official sources by `scripts/build_ffmpeg.sh`. The build is configured with `--enable-gpl --enable-version3`, so the bundled `ffmpeg` and `ffprobe` are distributed under the GNU General Public License version 3.

| Component | Version | License | Source |
|-----------|---------|---------|--------|
| FFmpeg | 9.0.2 | GPL-3.0 (as built) | https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz |
| x264 | r3222 (b35605a) | GPL-2.0-or-later | https://code.videolan.org/videolan/x264 |
| x265 | 4.3 | GPL-2.0-or-later | https://github.com/Multicorewareinc/x265 |
| LAME | 4.0 | LGPL-2.0-or-later | https://lame.sourceforge.io |
| Opus | 1.6.1 | BSD-3-Clause | https://opus-codec.org |
| libvpx | 1.17.0 | BSD-3-Clause | https://chromium.googlesource.com/webm/libvpx |
| SVT-AV1 | 4.2.0 | BSD-3-Clause-Clear | https://gitlab.com/AOMediaCodec/SVT-AV1 |
| dav1d | 1.5.4 | BSD-2-Clause | https://code.videolan.org/videolan/dav1d |

The exact source archives used for each release are attached to that release on GitHub as `ffmpeg-sources-<version>.tar`, alongside the build script that produced the binaries.

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project. This app is not affiliated with or endorsed by the FFmpeg project.
