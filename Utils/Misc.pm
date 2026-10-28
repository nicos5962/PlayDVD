package Plugins::PlayDVD::Utils::Misc;

use strict;
use warnings;

use Slim::Utils::Misc;
use Slim::Music::Info;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.playdvd');
my $prefs = preferences('plugin.playdvd');

my %CODEC_MAP = (
    'ac3'       => 'ac3',
    'eac3'      => 'eac3',
    'dts'       => 'dts',
    'aac'       => 'aac',
    'truehd'    => 'truehd',
    'flac'      => 'flac',
    'mp3'       => 'mp3',
    'pcm_s16le' => 'pcm',
    'pcm_s24le' => 'pcm',
);

sub pathFromFileURL {
	my $url     = shift;
	my $noCache = shift || 0;

	$url 		=~ s/^dvd:/file:/;
	my $path	= Slim::Utils::Misc::pathFromFileURL($url);
	return $path;
}

sub fileURLFromPath {
	my $path 	= shift;
	
	my $url 	= Slim::Utils::Misc::fileURLFromPath($path);	
	$url 		=~ s/^file:/dvd:/;	
	return $url;	
}

sub isDVD {
	my $pathOrObj = shift;
	my $type      = shift;

	if (!$type) {
		$type = Slim::Music::Info::_isContentTypeHelper($pathOrObj, $type);
	}
	elsif ($type eq 'application/octet-stream') {
		$type = Slim::Music::Info::_isContentTypeHelper($pathOrObj);
	}

	if ($type && $Slim::Music::Info::slimTypes{$type} && $Slim::Music::Info::slimTypes{$type} eq 'dvd') {
		return $type;
	}
}

sub isDVDURL {
    my ($class, $url) = @_;
    if ($url =~ /^dvd:/) {
        return 1;    
    } else {
        return 0;          
    }
}

sub getStreamingFormat {
	my ($class, $url) = @_;
	my $path = Plugins::PlayDVD::Utils::Misc::pathFromFileURL($url);
    my $codec = `ffprobe -v quiet -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$path"`;
    chomp $codec;
	$log->error("codec " . Data::Dump::dump($codec));
	return $CODEC_MAP{$codec} || $codec;
}

sub mac {
    my ($class, $client) = @_;  
	my $mac 	= lc($client->macaddress);	$mac	=~ s/:/-/g;   
	return $mac;
}

1;
