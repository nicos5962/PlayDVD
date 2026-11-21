package Plugins::PlayDVD::ProtocolHandler;

use strict;
use warnings;

use Slim::Utils::Log;

use constant DEFAULT_AUDIO_INFO => 'ac3, 48000 Hz, 192 kb/s';

my $log = logger('plugin.playdvd');

sub isRemote {
    return 1;
}

sub getMetadataFor {
    my ( $class, $client, $url ) = @_;

    return { bitrate => DEFAULT_AUDIO_INFO } unless $client;

    $client->currentPlaylistUpdateTime( Time::HiRes::time() );
    Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
    return {
        bitrate => DEFAULT_AUDIO_INFO,
    };
}

sub trackInfoURL {
    my ( $class, $client, $url ) = @_;
# This routine is called from package Slim::Menu::TrackInfo, sub menu
# Protocol Handlers can define their own track info OPML menus
# This is the page with track info
# Return so that standard menu is displayed
    my $tags        = {};
    my $track       = Slim::Schema->rs('Track')->single({ 'url' => $url });
    my $items       = [];

    my $itemInfoContributors    = Slim::Menu::TrackInfo::infoContributors( $client, $url, $track );
    $class->_addItems($itemInfoContributors, $items);

    my $itemInfoAlbum   = Slim::Menu::TrackInfo::infoAlbum( $client, $url, $track );
    $class->_addItems($itemInfoAlbum, $items);

    my $itemInfoYear    = Slim::Menu::TrackInfo::infoYear( $client, $url, $track );
    $class->_addItems($itemInfoYear, $items);

    my $itemInfoComment = Slim::Menu::TrackInfo::infoComment( $client, $url, $track );
    $class->_addItems($itemInfoComment, $items);

    my $itemInfoDuration        = Slim::Menu::TrackInfo::infoDuration( $client, $url, $track );
    $class->_addItems($itemInfoDuration, $items);

    my $iteminfoAudioStreams    = $class->_infoAudioStreams( $client, $url, $track );
    $class->_addItems($iteminfoAudioStreams, $items);

    my $iteminfoUrl         = Slim::Menu::TrackInfo::infoUrl( $client, $url, $track );
    $class->_addItems($iteminfoUrl, $items);

    my $iteminfoLocation        = $class->_infoLocation( $client, $url, $track );
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

    my $turl    = $track->url;
    $turl       =~ s/\+\+\d+:\d+$//;
    $turl       =~ s/^dvd:/file:/;

    my $weblink     = '/music/' . $track->id . '/download';

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
    my $device;     my $streamsLine;    my $item;
    my $title;      my $chapter;        my $nextTitle;
#Display all audio streams of DVD title
    $device         = $url;
    $device         =~ s/\+\+.*$//;
    $device         =~ s/^dvd:/file:/;
    $device         = Slim::Utils::Misc::pathFromFileURL($device);
    $device         =~ s/\/VIDEO_TS\/.*$//;
    $device         =~ s/\?title=.*$//;
    if ($url =~ /\?title=([^&]+)/) {
        $title = sprintf("%02d", $1);
    }
    if ( -f $device && $device =~ /\.(?:mkv|webm|mp4|m4v|ts|m2ts|mts|avi|mpg|mpeg)$/i ) {
        # a plain video file, not a disc: lsdvd can not read it
        $streamsLine    = $class->_ffprobeAudio($device);
    }
    else {
        my $lsdvdOutput = $class->_lsdvd($device);

        ($streamsLine)  = $lsdvdOutput =~ /(Title: $title.*?)(?:Title: |$)/s if defined $title;
    }
    $streamsLine        //= '';

    $item = {
        label   => "PLUGIN_PLAYDVD_AUDIO_STREAMS",
        name    => $streamsLine,
        type    => "text",
    };

    return $item;
}

# Audio streams of a video file: the audio "Stream #" lines exactly as ffprobe prints
# them, one per line, e.g.
#   Stream #0:1(eng): Audio: ac3, 48000 Hz, 5.1(side), fltp, 384 kb/s (default)
# Called for every track info menu, so remembered per file and modification time.
my %ffprobeCache;

sub _ffprobeAudio {
    my ($class, $file) = @_;

    my $key = join '|', $file, ( stat $file )[9] // 0;
    return $ffprobeCache{$key} if defined $ffprobeCache{$key};

    # list form open: no shell, so a quote in the path can not break (or inject into) the command;
    # ffprobe prints its report on stderr
    my @lines;
    if ( open(my $fh, '-|', '/bin/sh', '-c', 'exec "$0" "$@" 2>&1', '/usr/bin/timeout', 20, 'ffprobe', '-hide_banner', '-i', $file) ) {
        while ( my $line = <$fh> ) {
            next unless $line =~ /^\s*Stream #\d+:\d+.*?: Audio:/;
            $line =~ s/^\s+|\s+$//g;
            push @lines, $line;
        }
        close $fh;
    }
    else {
        $log->error("Cannot run ffprobe: $!");
        return '';
    }

    return '' unless @lines;
    return $ffprobeCache{$key} = join( "\n", @lines );
}

# lsdvd output per DVD. Called for every track info menu and it can take a while on an
# ISO, so remember it (the content of a DVD does not change while the server runs).
my %lsdvdCache;

sub _lsdvd {
    my ($class, $device) = @_;

    return $lsdvdCache{$device} if defined $lsdvdCache{$device};

    # list form open: no shell, so a quote in the path can not break (or inject into) the command
    my $output = '';
    if ( open(my $fh, '-|', '/usr/bin/timeout', 45, 'lsdvd', '-a', $device) ) {
        local $/;
        $output = <$fh> // '';
        close $fh;
    }
    else {
        $log->error("Cannot run lsdvd: $!");
        return '';
    }

    # do not cache failures (timeout, lsdvd missing), try again next time
    $lsdvdCache{$device} = $output if length $output;
    return $output;
}

sub formatOverride { 'iso' }

1;
