package Plugins::PlayDVD::ProtocolHandler;

use strict;
use warnings;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use File::Spec::Functions qw(catfile);
use constant DEFAULT_AUDIO_INFO => 'ac3, 48000 Hz, 192 kb/s'; 

my $log   = logger('plugin.playdvd');

sub isRemote { 
	return 1; 
}

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;

	my $track			= Slim::Schema->rs('Track')->single({ 'url' => $url });	
	my $bitrate		= "ac3, 48000 Hz, 192 kb/s";
	if ($client && $client->playingSong && $client->playingSong->track->url eq $url) {
		$bitrate =  $class->_getAudioStreamBitrate($client, $url, $track),   
	}
	$client->currentPlaylistUpdateTime( Time::HiRes::time() );			
	Slim::Control::Request::notifyFromArray($client, ['newmetadata']);			
	return {
		bitrate   	=> $bitrate,		
	};
}	

sub trackInfoURL { 
	my ( $class, $client, $url ) = @_;
# This routine is called from package Slim::Menu::TrackInfo, sub menu
# Protocol Handlers can define their own track info OPML menus
# This is the page with track info
# Return so that standard menu is displayed
	my $tags 		= {};
	my $track 		= Slim::Schema->rs('Track')->single({ 'url' => $url });		
	my $items 		= [];	

	my $itemInfoContributors	= Slim::Menu::TrackInfo::infoContributors( $client, $url, $track );
	$class->_addItems($itemInfoContributors, $items);

	my $itemInfoAlbum	= Slim::Menu::TrackInfo::infoAlbum( $client, $url, $track );
	$class->_addItems($itemInfoAlbum, $items);

	my $itemInfoYear	= Slim::Menu::TrackInfo::infoYear( $client, $url, $track );
	$class->_addItems($itemInfoYear, $items);

	my $itemInfoComment	= Slim::Menu::TrackInfo::infoComment( $client, $url, $track );
	$class->_addItems($itemInfoComment, $items);	
	
	my $itemInfoDuration		= Slim::Menu::TrackInfo::infoDuration( $client, $url, $track );
	$class->_addItems($itemInfoDuration, $items);	

	my $iteminfoAudioStreams	= $class->_infoAudioStreams( $client, $url, $track );
	$class->_addItems($iteminfoAudioStreams, $items);

	my $iteminfoUrl			= Slim::Menu::TrackInfo::infoUrl( $client, $url, $track );
	$class->_addItems($iteminfoUrl, $items);

	my $iteminfoLocation		= $class->_infoLocation( $client, $url, $track );
	$class->_addItems($iteminfoLocation, $items);

	return {
		name  => $track->title || Slim::Music::Info::getCurrentTitle( $client, $url, 1 ),
		type  => 'opml',
		items => $items,
		play  => $track->url,
		cover => '/music/' . ($track->coverid || 0) . '/cover.jpg',
		menuComplete => 1,
	};	
}

sub _infoLocation {
	my ( $class, $client, $url, $track ) = @_;

	my $turl 	= $track->url;
	$turl		=~ s/\+\+\d+:\d+$//;
	$turl		=~ s/^dvd:/file:/;
	
	my $weblink 	= '/music/' . $track->id . '/download';
	
	my $item = {
		type  => 'text',
		name  => Slim::Utils::Unicode::utf8decode_locale( Slim::Utils::Misc::pathFromFileURL($turl) ),
		label => 'LOCATION',
		weblink => $weblink,
	};
	return $item;
}

sub _addItems {
	my ($class, $item, $items) = @_;

	if ( ref $item eq 'ARRAY' ) {
		if ( scalar @{$item} ) {
			push @{$items}, @{$item};
		}
	} elsif ( ref $item eq 'HASH' ) {
		if ( scalar keys %{$item} ) {
			push @{$items}, $item;
		}
	} 
	else {
		return;
	}
}

sub _infoAudioStreams {
	my ($class, $client, $url, $track) = @_;
	my $device;		my $streamsLine;	my $item;
	my $title;		my $chapter;		my $nextTitle;
#Display all audio streams of DVD title
	$device			= $url;
	$device			=~ s/\+\+.*$//;
	$device			=~ s/^dvd:/file:/;
	$device			= Slim::Utils::Misc::pathFromFileURL($device);
	$device			=~ s/\/VIDEO_TS\/.*$//;
	$device 		=~ s/\?title=.*$//;
	if ($url =~ /\?title=([^&]+)/) {
		$title = sprintf("%02d", $1);
	}	
	my $lsdvdCommand	= `/usr/bin/timeout 45 lsdvd -a "$device"`;	
	
	$lsdvdCommand		=~ /(Title: $title.*?)(Title: |$)/s;
	$streamsLine		= $1;

	$item = {
		label	=> "PLUGIN_PLAYDVD_AUDIO_STREAMS", 
		name 	=> $streamsLine,
		type	=> "text", 
	};

	return $item;
}

sub formatOverride { 'iso' }

# $index (optional): 0-based audio stream number = astreamselect "map" value.
# Without it, the stream ffmpeg chose in "Stream mapping:" is used.
sub _getAudioStreamBitrate {
	my ($class, $client, $url, $track) = @_;
	my $info = Plugins::PlayDVD::Plugin::currentAudioInfo($client) or return;
	return $info->{text};          # or $info->{label} if you want "2/3 French - ..."
}
1;
