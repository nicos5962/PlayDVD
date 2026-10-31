# PlayDVD

Lyrion Music Server (LMS) plugin to import DVDs / DVD ISOs into the library and play their audio titles.

## Features
- Library importer for `VIDEO_TS` folders, `.iso`/`.img` images and `.vob` files, stored as `dvd://` tracks (one virtual track per DVD title). Scans detect new, deleted and changed DVDs, as the core scanner does.
- Tags (artist, album, year, disc, cover) are derived from the folder name.
- Transcoding to FLAC / MP3 / WAV / PCM through `Bin/DVD-Transcode` (basic) or `Bin/DVD-advanced-Transcode` (live audio-track switching).
- Audio stream selector from the player UI (ffmpeg `astreamselect` driven over ZMQ).

## Requirements
- LMS 9.x
- `ffmpeg` (with `azmq` for the advanced binary) and `ffprobe`
- `zmqsend` (advanced binary only)
- `mplayer` (title discovery while scanning) and `lsdvd` (audio stream info)
- `curl` (used by `Bin/jsonrpc`)

## Installation
Copy this folder to the LMS `Plugins` directory as `PlayDVD`, restart LMS, then open
*Settings > Advanced > Play DVD* to check dependencies and choose the binary.

## Notes
- Helper scripts and logs live in `<LMS prefs>/PlayDVD`. The transcode scripts default to `/config/prefs/PlayDVD` (Docker image layout); override with `PLAYDVD_BASEDIR`.
- Supported folder naming patterns are listed in `Formats/DVD.pm` (`_doAlbumArtistMapping`).
