package Plugins::PlayDVD::Utils::Misc;

use strict;
use warnings;

use Slim::Utils::Misc;

# The DVD records are stored with a dvd:// url. Apart from the scheme it is the
# file url of the disc image or VOB file, with a ?title=N query for the titles.

sub pathFromFileURL {
    my $url = shift;

    $url =~ s/^dvd:/file:/;

    return Slim::Utils::Misc::pathFromFileURL($url);
}

sub fileURLFromPath {
    my $path = shift;

    my $url = Slim::Utils::Misc::fileURLFromPath($path);
    $url =~ s/^file:/dvd:/;

    return $url;
}

1;
