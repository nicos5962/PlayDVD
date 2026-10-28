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

my $log 	= logger('plugin.playdvd');
my $prefs 	= preferences('plugin.playdvd');

my %StreamsMappingSampleSize = (
        'drc'		=> '32',
        '16bit'		=> '16',
        );

sub getTag {
	my $class 	= shift;
	my $url  	= shift || return {};
	my $anchor 	= shift || "";
	my ($filter, $md5_size, $md5_offset);

my $tags = {};
my $file = Plugins::PlayDVD::Utils::Misc::pathFromFileURL($url);
$tags->{FILENAME} 	= $file;
$tags->{URI}  		= Plugins::PlayDVD::Utils::Misc::fileURLFromPath($tags->{FILENAME});
$tags->{RELEASETYPE} 	= 'DVD';
	my $dirname  		= dirname($file);
	my $basename 		= basename($file);
	
#$file is the full path of the file being scanned
	$class->_doContentTypeMapping($tags, $basename);				#Content Type
	my $skipFile		= $class->_doCheckFileSkip($tags, $basename, $dirname);	#Process Only 1 VOB file per forder
	return if $skipFile;
	$class->_doArtworkMapping($tags, $dirname);					#Search for artwork
	$class->_doDiscNumMappingFromFilename($tags, $basename);
	$class->_doDiscNumMappingFromDirname($tags, $dirname);
	$class->_doAlbumArtistMappingFromDirname($tags, $dirname);
	my $tracks 		= $class->_doDVDScan($tags, $dirname, $file);
	$class->_doDebug($tags, $dirname, $file);
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
                $track->{CHANNELS} 	= 6;
                $track->{BITRATE} 	= 123456;
                next unless exists $track->{URI};                    
                my $trackid = Slim::Schema->updateOrCreate( {
                        url        	=> $track->{URI},
                        attributes 	=> $track,
                        readTags   	=> 0,  # avoid the loop, don't read tags
								commit	   		=> 1,
								integrateRemote => 1,  	
# only "file" and "db" handlers are considered local. All others are considered remote. See my %localHandlers in Slim::Player::ProtocolHandlers
                } );		
#			$log->debug("Current track attributes " . Data::Dump::dump($track));	               
#			my $trackxx = Slim::Schema->objectForUrl( {
#				url => $track->{URI},
#			} );	
#			$log->debug("Current trackdb " . Data::Dump::dump($trackxx));	       
        }		
	return $tags;
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
	my $cmd = "mplayer dvd:// -vo null -ao null -identify -frames 0 -dvd-device \"$device\" 2>/dev/null";
	open my $fh, "-|", $cmd or die "Can't run $cmd: $!";
	while (<$fh>) {
	   	if (/^ID_DVD_TITLE_(\d+)_LENGTH=(\d+\.\d+)/) {
	   		$currtrack 	= $1;
	   		$length		= $2;
			$tracks->{$currtrack}->{TRACKNUM}		= $currtrack;
			$tracks->{$currtrack}->{SECS}			= $length;
			$tracks->{$currtrack}->{START}			= $tracks->{$currtrack-1}->{END} || 0;   			
			$tracks->{$currtrack}->{END}			= $tracks->{$currtrack}->{START} + $tracks->{$currtrack}->{SECS};
			$tracks->{$currtrack}->{AUDIO}  		= 1;
			$tracks->{$currtrack}->{TITLE} 			= 'DVD#' . $currtrack . ':' . "1";
			foreach ('CONTENT_TYPE', 'COVER', 'DISC', 'COMMENT', 'ARTIST', 'ALBUM', 'YEAR', 'ALBUM_EXTID', 'RELEASETYPE') {
#			foreach ('CONTENT_TYPE', 'COVER', 'DISC', 'COMMENT', 'ARTIST', 'ALBUM', 'YEAR', 'EXTID', 'RELEASETYPE') {			
				$tracks->{$currtrack}->{$_} = $tags->{$_} if exists $tags->{$_};
			}
			$tracks->{$currtrack}->{URI}			= Plugins::PlayDVD::Utils::Misc::fileURLFromPath($file) . "?title=" . $currtrack;
#			$tracks->{$currtrack}->{URI}			= Plugins::PlayDVD::Utils::Misc::fileURLFromPath($file) . '++' . $currtrack . ':' . "1";
# For local files (url starts with file://) adding "++" in the Url is causing some issue in Slim:Schema-> find.
# The track becomes no more "in storage".
# "#" is allowed for tracks with embedded cuesheet (begins : ends).
# For DVDs it means Track : Chapter			
		}
		if (/^ID_AUDIO_BITRATE(\d+)/) {
			$bitrate	= $1;
		}
		if (/^ID_AUDIO_RATE(\d+)/) {
			$rate		= $1;
		}
		if (/^ID_AUDIO_NCH(\d+)/) {
			$channels	= $1;
		}				
	}
	close $fh;
	foreach my $tracknum (keys %$tracks) {
	    $tracks->{$tracknum}->{CHANNELS} 	= $channels;
	    $tracks->{$tracknum}->{RATE} 			= $rate;
	    $tracks->{$tracknum}->{BITRATE} 		= $bitrate;
	}

	$log->debug("	... found " . $currtrack . " tracks");
	return $tracks;	
}

sub _doDebug {
	my ($class, $tags, $dirname, $file) = @_;
	$log->debug("		... found CONTENT_TYPE 	= " . $tags->{CONTENT_TYPE}) if $tags->{CONTENT_TYPE};	
	$log->debug("		... found COVER 	= " . $tags->{COVER}) if $tags->{COVER};	
  	$log->debug("		... found DISC 		= " . $tags->{DISC}) if $tags->{DISC};
  	$log->debug("		... found COMMENT 	= " . $tags->{COMMENT}) if $tags->{COMMENT};
  	$log->debug("		... found ARTIST 	= " . $tags->{ARTIST}) if $tags->{ARTIST};
  	$log->debug("		... found ALBUM 	= " . $tags->{ALBUM}) if $tags->{ALBUM};  
  	$log->debug("		... found YEAR 		= " . $tags->{YEAR}) if $tags->{YEAR};
  	$log->debug("		... found ALBUM_EXTID 	= " . $tags->{ALBUM_EXTID}) if $tags->{ALBUM_EXTID};  
}

sub _doAlbumArtistMappingFromDirname {
	my ($class, $tags, $dirname) = @_;
	
	$dirname = $dirname . "/";
	
   if ( $dirname =~ m{.*/([^/]+)/\((\d{4})\)\s+(.*?)\s+\[.*?\[r(\d+)\]/} ) {
        $tags->{'ARTIST'}      = $1;
        $tags->{'YEAR'}        = $2;
        my $album_full         = $3;
        $album_full =~ s/\s*\[.*\]$//;          # optional: strip edition info
        $tags->{'ALBUM'}       = $album_full;
        $tags->{'ALBUM_EXTID'} = $4;
        return;
    }	

    if ( $dirname =~ m{.*/([^/]+)/\((\d{4}-\d{2}-\d{2})\)\s+(.*?)\s+\[(.*?)\]/} ) {
        $tags->{'ARTIST'}   = $1;
        $tags->{'YEAR'}     = $2;
        my $album_full      = $tags->{'YEAR'} . ' ' . $3;
        $album_full =~ s/\s*\[.*\]$//;   # safety strip if needed       
        $tags->{'ALBUM'}    = $album_full;
        $tags->{'YEAR'}     = substr($tags->{'YEAR'}, 0, 4);        
        return;
    }

	if ( $dirname 	=~  m/^(.*)\/(.*?) - (.*) - (19[56789]\d{1}|20[01234]\d{1}) - (\d+)\/.*$/) {	
		$tags->{'ARTIST'} 		= $2; 
		$tags->{'ALBUM'} 		= $3;
		$tags->{'YEAR'} 		= $4;
		$tags->{'ALBUM_EXTID'} 		= $5;
		return;
	}
	if ( $dirname =~  m/^(.*)\/(.*?) - (.*) - (19[56789]\d{1}|20[01234]\d{1})\/.*$/ ) {			# /ARTIST - ALBUM - YEAR/
		$tags->{'ARTIST'} 		= $2; 
		$tags->{'ALBUM'} 		= $3;
		$tags->{'YEAR'} 		= $4;
		return;
	}
	if ( $dirname =~  m/^(.*)\/(.*?) - (19[56789]\d{1}|20[01234]\d{1}) - (.*?)\/.*$/ ) {			# /ARTIST - YEAR - ALBUM/
		$tags->{'ARTIST'} 		= $2; 
		$tags->{'ALBUM'} 		= $4;
		$tags->{'YEAR'} 		= $3;
		return;
	}	
	if ( $dirname =~  m/^(.*)\/(\[.*\]) (.*?) - (\d{4}\S{1}\d{2}\S{1}\d{2}) - (.*?)\/.*$/ ) {	
		$tags->{'COMMENT'}		= $2;
		$tags->{'ARTIST'} 		= $3; 
		$tags->{'ALBUM'} 		= $5;
		my $date			= $4;
		$tags->{'YEAR'} 		= substr( $date,0,4 );
		$tags->{'ALBUM'}		= $date . ' - ' . $tags->{'ALBUM'} . ' ' . $tags->{'COMMENT'}; 	
		return;
	}
	if ( $dirname =~  m/^(.*)\/(.*?) - (\d{4}\S{1}\d{2}\S{1}\d{2}) - (.*?)\/.*$/ ) {	
		$tags->{'ARTIST'} 		= $2; 
		$tags->{'ALBUM'} 		= $4;
		my $date			= $3;
		$date				=~  s/\./\//g;
		$tags->{'YEAR'} 		= substr( $date,0,4 );
		$tags->{'ALBUM'}		= $date . ' - ' . $tags->{'ALBUM'}; 		
		return;
	}
	if ( $dirname =~  m/^(.*)\/(.*?) - (\d{4}\S{1}\d{2}\S{1}\d{2}) (.*?)\/.*$/ ) {	
		$tags->{'ARTIST'} 		= $2; 
		$tags->{'ALBUM'} 		= $4;
		my $date			= $3;	
		$date				=~  s/\./\//g;
		$tags->{'YEAR'} 		= substr( $date,0,4 );
		$tags->{'ALBUM'}		= $date . ' - ' . $tags->{'ALBUM'}; 	
		return;
	}	
	if ( $dirname =~  m/^(.*)\/(.*?) - (\d{4}\S{1}\d{2}\S{1}\d{2}) - (.*?)\/.*$/ ) {	
		$tags->{'ARTIST'} 		= $2; 
		my $date			= $3;	
		$tags->{'ALBUM'} 		= $4;
		$date				=~  s/\./\//g;		
		$tags->{'YEAR'} 		= substr( $date,0,4 );
		$tags->{'ALBUM'}		= $date . ' - ' . $tags->{'ALBUM'}; 	
		return;
	}			
	 $log->debug("		... Parsing forlder KO " . $dirname);
}

sub _doDiscNumMappingFromFilename {
	my ($class, $tags, $basename) = @_;

	if ($basename =~ /dvd(\d+)/) {
  		$tags->{'DISC'} 		= $1;
	}
	if ( $basename 	=~  m/(DVD\s*\d+)(.*).iso/) {
  		$tags->{'DISC'} 		= $1;
  		$tags->{'COMMENT'} 		= $2;	  		
	}
	if ( $basename 	=~  m/(DISC\s*\d+)(.*).iso/) {
  		$tags->{'DISC'} 		= $1;
  		$tags->{'COMMENT'} 		= $2;  		
	}	
	if ( $basename 	=~  m/(Disc\s*\d+)(.*).iso/) {
  		$tags->{'DISC'} 		= $1;
  		$tags->{'COMMENT'} 		= $2;  		
	}	
	if ( $basename 	=~  m/(disc\s*\d+)(.*).iso/) {
  		$tags->{'DISC'} 		= $1;
  		$tags->{'COMMENT'} 		= $2;  		
	}
	
	$tags->{'DISC'}			=~ s/\D//g;	
	$tags->{'COMMENT'} 		=~ s/^_//;
	$tags->{'COMMENT'} 		=~ s/^(|)$//;  		
}

sub _doDiscNumMappingFromDirname {
	my ($class, $tags, $dirname) = @_;
	if ( $dirname 	=~  m/\/(DVD\s*\d+)\s*(.*?)\//) {		# ex /DVD1 xxxx/ or /DVD 1 xxxx/
  		$tags->{'DISC'} 		= $1;
  		$tags->{'COMMENT'} 		= $2;	  		
	}
	if ( $dirname 	=~  m/\/(DISC\s*\d+)\s*(.*?)\//) {		
  		$tags->{'DISC'} 		= $1;
  		$tags->{'COMMENT'} 		= $2;	  		
	}
	if ( $dirname 	=~  m/\/(Disc\s*\d+)\s*(.*?)\//) {			
  		$tags->{'DISC'} 		= $1;
  		$tags->{'COMMENT'} 		= $2;	
	}
	if ( $dirname 	=~  m/\/(disc\s*\d+)\s*(.*?)\//) {		
  		$tags->{'DISC'} 		= $1;
  		$tags->{'COMMENT'} 		= $2;	  		
	}
	if ( $dirname 	=~  m/\/(dvd\s*\d+)\s*(.*?)\//) {		
  		$tags->{'DISC'} 		= $1;
  		$tags->{'COMMENT'} 		= $2;	  		
	}
	$tags->{'DISC'}			=~ s/\D//g;	
	$tags->{'COMMENT'}		=~ s/^\s*//;	
	$tags->{'COMMENT'}		=~ s/^- //;		
}

sub _doCheckFileSkip {
	my ($class, $tags, $basename, $dirname) = @_;

	return 0 if $tags->{CONTENT_TYPE} ne 'dvd';	
	
	opendir(MYDIR, $dirname);
	my @files = grep { /.VOB/ } readdir MYDIR;
	close MYDIR;	
	sort @files;

	if ( @files[0]  eq $basename ) {
		return 0
	} else { 
		$log->debug("	... Skipping file $basename...");	
		return 1;
	}
}

sub _doContentTypeMapping {
	my ($class, $tags, $basename) = @_;

	my $extension 		= lc(( split /\./, $basename )[-1]);
	$tags->{CONTENT_TYPE}	= $Slim::Music::Info::suffixes{$extension};
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

sub canSeek { 0 }
# No seek for DVD

1;
