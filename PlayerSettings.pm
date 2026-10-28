package Plugins::PlayDVD::PlayerSettings;

use strict;

use base qw(Slim::Web::Settings);
use JSON::XS;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Player::CapabilitiesHelper;

use Slim::Utils::Strings qw(string);
use Slim::Utils::Strings qw(cstring);

my $prefs = preferences('plugin.playdvd');

my $log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.playdvd',
    'defaultLevel' => 'WARN',
    'description'  => getDisplayName(),
                                         });
sub getDisplayName {
    return 'PLUGIN_PLAYDVD';
}

sub new {
	my $class = shift;
	my $plugin   = shift;
	$class->SUPER::new;
}

sub needsClient {
    return 1;
}

sub name {
    return Slim::Web::HTTP::CSRF->protectName('PLUGIN_PLAYDVD');
}

sub page {
    return Slim::Web::HTTP::CSRF->protectURI('plugins/PlayDVD/settings/player.html');
}

sub handler {
	my ($class, $client, $params, $callback, @args) = @_;

	return $class->SUPER::handler($client, $params);
}

sub getPrefs {
    return $prefs;
}

1;
