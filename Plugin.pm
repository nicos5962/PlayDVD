package Plugins::PlayDVD::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use Slim::Player::ProtocolHandlers;
use Slim::Utils::Log;
use Plugins::PlayDVD::Register;

my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.playdvd',
    defaultLevel => 'INFO',
    description  => 'PLUGIN_PLAYDVD',
});

sub initPlugin {
    my $class = shift;

    my $version = $class->_pluginDataFor('version') || 'unknown';
    $log->info("Initializing PlayDVD plugin $version");

    Slim::Player::ProtocolHandlers->registerHandler(
        dvd => 'Plugins::PlayDVD::ProtocolHandler'
    );

    Plugins::PlayDVD::Register->registerFormatHandler();

    $class->SUPER::initPlugin(@_);
}

sub getDisplayName { 'PLUGIN_PLAYDVD' }

1;
