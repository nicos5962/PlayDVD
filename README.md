# PlayDVD

Lyrion Music Server (LMS) plugin to import DVDs / DVD ISOs into the library and play their audio titles.

## Features
- Library importer for `VIDEO_TS` folders, `.iso`/`.img` images and `.vob` files, stored as `dvd://` tracks (one virtual track per DVD title, `?title=N`). The importer has its own scan logic: it finds new, deleted and changed DVDs, as the core scanner does for files.
- Tags (artist, album, year, disc, cover) are derived from the folder name.
- Transcoding to FLAC / MP3 / WAV / PCM through `Bin/DVD-Transcode` (ffmpeg).
- The track info page lists the audio streams of the title.

## Requirements
- LMS 9.x
- `ffmpeg` and `ffprobe`
- `mplayer` (title discovery while scanning) and `lsdvd` (audio streams in track info)

## Installation
Copy this folder to the LMS `Plugins` directory as `PlayDVD` and restart LMS. A rescan imports the DVDs.

## Notes
- Transcode logs live in `<LMS prefs>/PlayDVD/remote_players`. The script defaults to `/config/prefs/PlayDVD` (Docker image layout); override with `PLAYDVD_BASEDIR`.
- A title is played from its start: the script takes no seek offset.
- Supported folder naming patterns are listed in `Formats/DVD.pm` (`_doAlbumArtistMapping`).
