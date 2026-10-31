package Plugins::PlayDVD::Formats::DVD;

use strict;
use Slim::Utils::Log;
use JSON::XS;
use File::Basename;
use File::Temp ();
use Slim::Utils::Prefs;
use File::Slurp;
use URI::Escape;
use Plugins::PlayDVD::Utils::Misc;

my $log 		= logger('plugin.playdvd');
my $prefs 	= preferences('plugin.playdvd');

sub getTag {
	my $class 			= shift;
	my $url  				= shift || return {};
	my $anchor 			= shift || "";
	my ($filter, $md5_size, $md5_offset);
#$url has "file://" prefix

	my $tags = {};

	my $file 			= Plugins::PlayDVD::Utils::Misc::pathFromFileURL($url);
	my $dirname 		= dirname($file);
	my $basename		= basename($file);

	$class->_doContentTypeMapping($tags, $basename);				#Content Type
	my $skipFile		= $class->_doCheckFileSkip($tags, $basename, $dirname);	#Process Only 1 VOB file per forder
	return if $skipFile;

	$class->_doArtworkMapping($tags, $dirname);						#Search for artwork
	$class->_doDiscNumMapping($tags, $dirname, $basename);			#Search for disc number
	$class->_doAlbumArtistMapping($tags, $dirname, $basename);	#Search for album, artist

	$tags->{FILENAME} 	= $file;
	$tags->{URI}  		= Plugins::PlayDVD::Utils::Misc::fileURLFromPath($tags->{FILENAME});
	# Used by the importer to detect changed DVDs (compared with scanned_files)
	@$tags{qw(FILESIZE TIMESTAMP)} = (stat($file))[7,9];

	my $tracks 		= $class->_doDVDScan($tags, $dirname, $file);
	$tags->{AUDIO} 		= 0;
	$tags->{CT}    		= "fec";
	$tags->{CONTENT_TYPE}   = "fec";

### Need also to save main file as non virtual
	my $trackid = Slim::Schema->updateOrCreate( {
		url        	=> $tags->{URI},
		attributes 	=> $tags,
		readTags   	=> 0,  # avoid the loop, don't read tags
		commit	   	=> 1,
		integrateRemote => 1,
	} );

	for my $key ( sort { $a <=> $b } keys %$tracks ) {
		my $track = $tracks->{$key};
		$track->{VIRTUAL} 	= 1;

		next unless exists $track->{URI};
		my $trackid = Slim::Schema->updateOrCreate( {
			url        			=> $track->{URI},
			attributes 			=> $track,
			readTags   			=> 0,  # avoid the loop, don't read tags
			commit	   				=> 1,
			integrateRemote 	=> 1,
# only "file" and "db" handlers are considered local. All others are considered remote. See my %localHandlers in Slim::Player::ProtocolHandlers
		} );
	}
	return $tags;
}

sub canSeek { 0 }
# No seek for DVD

sub _doContentTypeMapping {
	my ($class, $tags, $basename) = @_;

	my $extension 		= lc(( split /\./, $basename )[-1]);
	$tags->{CONTENT_TYPE}	= $Slim::Music::Info::suffixes{$extension};
}

sub _doCheckFileSkip {
	my ($class, $tags, $basename, $dirname) = @_;

	return 0 if $tags->{CONTENT_TYPE} ne 'dvd';

	# Must pick the same file as Importer::_keepFirstVOBPerFolder
	opendir(my $dh, $dirname) or return 0;
	my @files = sort grep { /\.vob$/i } readdir $dh;
	closedir $dh;

	if ( $files[0] eq $basename ) {
		return 0
	} else {
		return 1;
	}
}

sub _doArtworkMapping {
	my ($class, $tags, $dirname) = @_;

	if ( $dirname =~  /VIDEO_TS$/ ) {
		$dirname =~ s/VIDEO_TS$//;
	}
	$tags->{COVER} = Slim::Music::Artwork->findStandaloneArtwork(
		{},
		{},
		Slim::Utils::Misc::fileURLFromPath($dirname)
	);
}

sub _doDiscNumMapping {
	my ($class, $tags, $dirname, $basename) = @_;

	for my $name ($basename, $dirname) {
		 next unless defined $name;
		 if ($name =~ m{\b(?:dvd|disc|disk|cd)[\s._-]*(\d+)\b}i) {
		     $tags->{'DISC'} = $1;
		     return;
		 }
	}
}

sub _doAlbumArtistMapping {
	my ($class, $tags, $dirname, $basename) = @_;
	# Normalize dirname: ensure it ends with /
	$dirname =~ s{/?$}{/};

	#1. Artist / (YYYY) Album [anything] [r123]/
	if (
		 $dirname =~ m{
		     .*/([^/]+)/              # Artist
		     \((\d{4})\)\s+           # (YYYY)
		     (.*?)\s+                 # Album
		     \[.*?\]\s+               # [anything]
		     \[r(\d+)\]/              # [r123]
		 }x
	) {
		 my ($artist, $year, $album, $extid) = ($1, $2, $3, $4);
		 $album =~ s/\s*\[.*\]$//;
		 $tags->{'ARTIST'}      = $artist;
		 $tags->{'YEAR'}        = $year;
		 $tags->{'ALBUM'}       = $album;
		 $tags->{'ALBUM_EXTID'} = $extid;
		 return;
	}

	# 2. Artist / (YYYY-MM-DD | YYYY.MM.DD) Album [edition]?/ [optional subfolders]
	if (
		 $dirname =~ m{
		     .*/([^/]+)/                          # Artist
		     \((\d{4}[-.]\d{2}[-.]\d{2})\)\s+     # (YYYY-MM-DD) or (YYYY.MM.DD)
		     ([^/]+?)                             # Album
		     (?:\s+\[[^/]*\])?/                   # optional [edition]
		 }x
	) {
		 my ($artist, $date, $album) = ($1, $2, $3);
		 $date =~ s/\./-/g;                       # normalize dots to dashes
		 $tags->{'ARTIST'} = $artist;
		 $tags->{'YEAR'}   = substr($date, 0, 4);
		 $tags->{'ALBUM'}  = "$date $album";
		 return;
	}

	# 3. Artist - Album - YYYY - ID/
	if (
		 $dirname =~ m{
		     ^(.*)/
		     (.*?)\s+-\s+
		     (.*)\s+-\s+
		     ((?:19[56789]\d|20[01234]\d))
		     \s+-\s+
		     (\d+)/
		     .*$
		 }x
	) {
		 my ($artist, $album, $year, $extid) = ($2, $3, $4, $5);
		 $tags->{'ARTIST'}      = $artist;
		 $tags->{'ALBUM'}       = $album;
		 $tags->{'YEAR'}        = $year;
		 $tags->{'ALBUM_EXTID'} = $extid;
		 return;
	}

	# 4. Artist - Album - YYYY/
	if (
		 $dirname =~ m{
		     ^(.*)/
		     (.*?)\s+-\s+
		     (.*)\s+-\s+
		     ((?:19[56789]\d|20[01234]\d))/
		     .*$
		 }x
	) {
		 my ($artist, $album, $year) = ($2, $3, $4);
		 $tags->{'ARTIST'} = $artist;
		 $tags->{'ALBUM'}  = $album;
		 $tags->{'YEAR'}   = $year;
		 return;
	}

	# 5. Artist - YYYY - Album/
	if (
		 $dirname =~ m{
		     ^(.*)/
		     (.*?)\s+-\s+
		     ((?:19[56789]\d|20[01234]\d))
		     \s+-\s+
		     (.*?)/
		     .*$
		 }x
	) {
		 my ($artist, $year, $album) = ($2, $3, $4);
		 $tags->{'ARTIST'} = $artist;
		 $tags->{'ALBUM'}  = $album;
		 $tags->{'YEAR'}   = $year;
		 return;
	}

	# 6. [COMMENT] Artist - YYYY.MM.DD - Album/
	if (
		 $dirname =~ m{
		     ^(.*)/
		     (\[.*\])\s+
		     (.*?)\s+-\s+
		     (\d{4}\S\d{2}\S\d{2})
		     \s+-\s+
		     (.*?)/
		     .*$
		 }x
	) {
		 my ($comment, $artist, $date, $album) = ($2, $3, $4, $5);
		 $date =~ s/\./\//g;
		 $tags->{'COMMENT'} = $comment;
		 $tags->{'ARTIST'}  = $artist;
		 $tags->{'YEAR'}    = substr($date, 0, 4);
		 $tags->{'ALBUM'}   = "$date - $album $comment";
		 return;
	}

	# 7. Artist - YYYY.MM.DD - Album/
	# 8. Artist - YYYY.MM.DD Album/
	# These patterns share the same date/album extraction logic.
	if (
		 $dirname =~ m{
		     ^(.*)/
		     (.*?)\s+-\s+
		     (\d{4}\S\d{2}\S\d{2})
		     (?:\s+-\s+|\s+)
		     (.*?)/
		     .*$
		 }x
	) {
		 my ($artist, $date, $album) = ($2, $3, $4);
		 $date =~ s/\./\//g;
		 $tags->{'ARTIST'} = $artist;
		 $tags->{'YEAR'}   = substr($date, 0, 4);
		 $tags->{'ALBUM'}  = "$date - $album";
		 return;
	}
	# 9. Artist / (YYYY) Album / [optional subfolders, e.g. VIDEO_TS]/
	if (
		 $dirname =~ m{
		     .*/([^/]+)/              # Artist
		     \((\d{4})\)\s+           # (YYYY)
		     ([^/]+?)/                # Album
		     (?:[^/]+/)*$             # optional subdirs (VIDEO_TS, CD1, ...)
		 }x
	) {
		 my ($artist, $year, $album) = ($1, $2, $3);
		 $album =~ s/\s*\[.*\]$//;    # strip trailing [edition] if any
		 $tags->{'ARTIST'} = $artist;
		 $tags->{'YEAR'}   = $year;
		 $tags->{'ALBUM'}  = $album;
		 return;
	}
}

sub _doDVDScan {
	my ($class, $tags, $dirname, $file) = @_;

	my $tracks    = {};
	my $currtrack;	my $length;	my $bitrate;	my $rate;	my $channels;
	my $device;
	if ( $tags->{CONTENT_TYPE} ne 'dvd' ) {
		$device	= $file;
	} else {
		$device	= $dirname;
		$device =~ s/\/VIDEO_TS$//;
	}
	my @tag_names = qw(
		 CONTENT_TYPE COVER DISC COMMENT ARTIST ALBUM YEAR
		 ALBUM_EXTID RELEASETYPE
	);

	my ($currtrack, $bitrate, $rate, $channels);

	my $cmd = 'mplayer';

	my $fh;
	open($fh, '-|',
		 $cmd,
		 'dvd://',
		 '-vo', 'null',
		 '-ao', 'null',
		 '-identify',
		 '-frames', '0',
		 '-dvd-device', $device
	) or do {
		$log->error("Can't run $cmd (is it installed?), no titles found for $device: $!");
		return $tracks;
	};

	while (my $line = <$fh>) {
		 # DVD title information
		 if ($line =~ /^ID_DVD_TITLE_(\d+)_LENGTH=(\d+(?:\.\d+)?)/) {

		     my ($tracknum, $length) = ($1, $2);

		     $currtrack = $tracknum;

		     my $track = $tracks->{$tracknum} //= {};

		     $track->{TRACKNUM} = $tracknum;
		     $track->{SECS}     = $length;
		     $track->{START}    = 0;
		     $track->{END}      = $track->{START} + $track->{SECS};
		     $track->{AUDIO}    = 1;
		     $track->{TITLE}    = "DVD#$tracknum:1";

		     # Copy available tags
		     for my $tag (@tag_names) {
		         $track->{$tag} = $tags->{$tag}
		             if exists $tags->{$tag};
		     }

		     # Generate the track URI
		     $track->{URI} = $tags->{URI} . "?title=$tracknum";
		 }
		 # Audio bitrate
		 elsif ($line =~ /^ID_AUDIO_BITRATE(?:\d+)?=(\d+)/) {
		     $bitrate = $1;
		 }
		 # Audio sampling rate
		 elsif ($line =~ /^ID_AUDIO_RATE(?:\d+)?=(\d+)/) {
		     $rate = $1;
		 }
		 # Number of audio channels
		 elsif ($line =~ /^ID_AUDIO_NCH(?:\d+)?=(\d+)/) {
		     $channels = $1;
		 }
	}

	close $fh
		 or $log->warn("mplayer exited with an error: $? while scanning " . $dirname);

	# Apply audio metadata to all discovered tracks
	for my $tracknum (keys %$tracks) {

		 my $track = $tracks->{$tracknum};

		 $track->{CHANNELS} = $channels if defined $channels;
		 $track->{RATE}     = $rate     if defined $rate;
		 $track->{BITRATE}  = $bitrate  if defined $bitrate;
	}

	return $tracks;
}

1;
