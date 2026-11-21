package Plugins::PlayDVD::Register;

# Registers the PlayDVD tag handlers. Kept free of any web/UI dependency so it
# can be used by both the server plugin and the scanner importer.

use strict;
use warnings;

use Slim::Formats;
use Slim::Utils::Log;

use constant HANDLER => 'Plugins::PlayDVD::Formats::DVD';

my $log = logger('plugin.playdvd');

# Server types of the plugin (see custom-types.conf)
my @types = qw(dvd iso);

sub registerFormatHandler {
    my ($class, $tagClasses) = @_;

    Slim::Formats->init();

    $tagClasses ||= \%Slim::Formats::tagClasses;

    return 0 unless ref($tagClasses) eq 'HASH';

    for my $type (@types) {
        next if defined $tagClasses->{$type} && $tagClasses->{$type} eq HANDLER;

        $tagClasses->{$type} = HANDLER;

        main::DEBUGLOG && $log->is_debug && $log->debug("PlayDVD: registered $type tag handler");
    }

    return 1;
}

1;
