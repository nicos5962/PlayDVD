package Plugins::PlayDVD::Settings;

use strict;
use warnings;
use parent qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $log   = logger('plugin.playdvd');
my $prefs = preferences('plugin.playdvd');

sub name {
    # Localized string ID from strings.txt
    return 'PLUGIN_PLAYDVD';
}

sub page {
    return 'plugins/PlayDVD/settings/basic.html';
}

sub new {
    my ($class, $main_plugin) = @_;
    return $class->SUPER::new;
}

sub handler {
    my ($class, $client, $params) = @_;

	if ($params->{'saveSettings'}) {
		$prefs->set('prefered_binary', $params->{'binary_choice'} );
		my @srcfmts 		= ( 'dvd', 'iso');
		my @targetfmts 		= ( 'flc', 'mp3', 'pcm', 'wav');
		my ($prefBinary)	= $params->{'binary_choice'};
		foreach my $srcfmt (@srcfmts) {
			foreach my $targetfmt (@targetfmts) {			
				my $rule 	= $srcfmt . '-' . $targetfmt . '-*-*';
				my $transcode 	= $Slim::Player::TranscodingHelper::commandTable{$rule};
				$transcode 	=~ s/\[.*?\]/\[$prefBinary\]/;
				$Slim::Player::TranscodingHelper::commandTable{$rule} = $transcode;	
			}	
		}	
	}

	$params->{icon}							= "plugins/PlayDVD/html/images/icon.png";
	$params->{'ffmpeg_installed'}		=  check_ffmpeg_installed();
	$params->{'binaries'}					= check_binaries();
	$params->{'has_ffmpeg_zmq'}					=  check_ffmpeg_zmq();
	($params->{'has_zmqsend'}, $params->{'zmqsend_path'})	=  check_zmqsend();
	$params->{'prefered_binary'}				= $prefs->get('prefered_binary');
    my @devices;
    foreach my $client (Slim::Player::Client::clients()) {
        push @devices, {
            name => $client->name,
            mac  => $client->id,
            port => $prefs->client($client)->get('zmq_port'),
        };
    }  
    $params->{'devices'} = \@devices;    	
	
	return $class->SUPER::handler($client, $params);
}

sub check_ffmpeg_installed {
    my $output = `which ffmpeg 2>/dev/null`;
    if ($? == 0 && $output ne '') {
        chomp $output;
        return "yes";
    } else {
        return "no";
    }
}

sub check_binaries {
# List of candidate binaries
    my @candidates 	= qw(DVD-Transcode DVD-advanced-Transcode);
    my @available;		my $binaries;
    foreach my $bin (@candidates) {
	my $path = Slim::Utils::Misc::findbin($bin);
        if ($path) {
	    push @available, {
		    name 	=> $bin,
		    path  	=> $path,
		    version	=> `$path --version 2>&1`,
	    };        
        } 
	$binaries	= \@available;	
    }
    return $binaries; 
}

sub check_ffmpeg_zmq {
    my $cmd = `ffmpeg -hide_banner -filters 2>&1`;
    if ($cmd =~ /\bazmq\b/) {
        return "yes";
    } else {
        return "no";
    }
}

sub check_zmqsend {
	my $path = Slim::Utils::Misc::findbin('zmqsend');	
	if ( !$path ) {
		$path = qx(find /config/ -type f -name "zmqsend");
	}
	if ($path) {
		return ("yes", $path);
	} else {
		return ("no", $path);
	}
}
1;

