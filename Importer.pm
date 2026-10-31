package Plugins::PlayDVD::Importer;

# DVD importer. Modelled on Slim::Utils::Scanner::Local::rescan, which can not be used
# as is because it only handles "audio" types and works on file:// urls, whereas the
# DVD records are stored as dvd:// urls.
#
# Like the core scanner, 3 lists are built per media folder, by comparing the files
# found on disk (table scanned_files) with the tracks table:
#   1. dbonly   : DVDs in the library that no longer exist on disk   -> deleted
#   2. changed  : DVDs whose timestamp or size differ from the DB    -> deleted + re-added
#   3. diskonly : DVDs on disk that are not in the library           -> added
#
# Only the "main" record of a DVD (content type 'fec', not virtual) is compared. The
# virtual title tracks (<main url>?title=N) always follow their main record.

use strict;
use warnings;

use File::Basename qw(dirname basename);

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Plugins::PlayDVD::Utils::Misc;

use constant IS_SQLITE		=> (Slim::Utils::OSDetect->getOS()->sqlHelperClass() =~ /SQLite/ ? 1 : 0);
# Number of items to process at once, this value will affect the max size of the WAL file.
# Chunking is only required with SQLite, as we don't have this kind of concurrency problem with MySQL.
use constant CHUNK_SIZE		=> IS_SQLITE ? 50 : 1000;

my $log   = logger('plugin.playdvd');
my $prefs = preferences('plugin.playdvd');

sub initPlugin {
	my $class = shift;
	Slim::Music::Import->addImporter( $class, {
		type   => 'post',
		weight => 300,
		use    => 1,
	} );
}

sub startScan {
	my $class = shift;

	my $dirs  = shift || Slim::Utils::Misc::getMediaDirs();
	if (ref $dirs ne 'ARRAY' || scalar @{$dirs} == 0) {
		main::INFOLOG && $log->info("Skipping media folder scan - no folders defined.");
		Slim::Music::Import->endImporter($class);
		return 0;
	}

	# get singledir parameter from the scanner if available
	my $singledir = main::SCANNER ? $ARGV[-1] : undef;

	$dirs = Slim::Utils::Misc::getAudioDirs($singledir);
	$dirs = [ $dirs ] if $dirs && ref $dirs ne 'ARRAY';
	$dirs = [ grep { $_ } @{ $dirs || [] } ];

	if ( !scalar @$dirs ) {
		Slim::Music::Import->endImporter($class);
		return 0;
	}

	eval { require Plugins::PlayDVD::Formats::DVD };
	if ( $@ ) {
		$log->error("Unable to load Plugins::PlayDVD::Formats::DVD: $@");
		Slim::Music::Import->endImporter($class);
		return 0;
	}

	main::INFOLOG && $log->info("Starting dvd-only scan");

	my $args = {
		types     => 'dvd',
		scanName  => 'dvd',
		no_async  => 1,
		progress  => 1,
		recursive => 1,
	};

	my $changes = 0;

	foreach my $next (@$dirs) {
		last if Slim::Music::Import->hasAborted();

		$next = Slim::Utils::Unicode::encode_locale($next);
		$next =~ s{/$}{};
		next unless $next;

		$log->error("Discovering DVD files in $next") unless main::SCANNER && $main::progress;

		# find() clears the entries below $next in scanned_files first, and no_async
		# makes the callback run before it returns.
		Slim::Utils::Scanner::Local->find( $next, $args, sub {
			$changes += $class->_compareAndSync( $next, $args );
		} );
	}

	main::INFOLOG && $log->info("DVD scan done, $changes changes");

	Slim::Music::Import->endImporter($class);
}

sub _compareAndSync {
	my ($class, $next, $args) = @_;

	my $dbh = Slim::Schema->dbh;

	$class->_keepFirstVOBPerFolder($dbh);

	my $createTemporary = (main::DEBUGLOG && $log->is_debug) ? '' : 'TEMPORARY';
	my $order           = IS_SQLITE ? '' : ' ORDER BY url';

	# DB urls are dvd://, scanned_files urls are file:// (same escaping, only the scheme differs)
	my $dvdUrl = IS_SQLITE ? q{'dvd' || SUBSTR(url, 5)} : q{CONCAT('dvd', SUBSTR(url, 5))};

	# base folder as dvd:// url, with a trailing slash so /music/a does not match /music/ab
	my $basedir   = Plugins::PlayDVD::Utils::Misc::fileURLFromPath($next) . '/';
	my $baseLen   = length $basedir;
	my $baseQuote = $dbh->quote($basedir);
	my $inBase    = "SUBSTR(url, 1, $baseLen) = $baseQuote";

	$log->error("Build temporary table for DVD files on disk") unless main::SCANNER && $main::progress;
	$dbh->do('DROP TABLE IF EXISTS scanned_dvd');
	$dbh->do( qq{
		CREATE $createTemporary TABLE scanned_dvd AS
			SELECT DISTINCT $dvdUrl AS url, timestamp, filesize
			FROM   scanned_files
			WHERE  filesize != 0
	} );

	# 1. In the DB, no longer on disk (main records only, virtual title tracks follow)
	$dbh->do('DROP TABLE IF EXISTS dbonly');
	$dbh->do( qq{
		CREATE $createTemporary TABLE dbonly AS
			SELECT DISTINCT(url) AS url
			FROM   tracks
			WHERE  url NOT IN ( SELECT url FROM scanned_dvd )
			AND    $inBase
			AND    `virtual` IS NULL
			AND    content_type = 'fec'
	} );
	my $inDBOnlySQL = 'SELECT url FROM dbonly';

	# 2. On disk, not in the DB
	$dbh->do('DROP TABLE IF EXISTS diskonly');
	$dbh->do( qq{
		CREATE $createTemporary TABLE diskonly AS
			SELECT DISTINCT(url) AS url
			FROM   scanned_dvd
			WHERE  url NOT IN (
				SELECT url FROM tracks
				WHERE  `virtual` IS NULL AND content_type = 'fec'
			)
			AND    $inBase
	} );
	my $onDiskOnlySQL = 'SELECT url FROM diskonly';

	# 3. Changed mtime or size. Records imported by older versions of the plugin have
	#    no timestamp/size, they are refreshed once.
	$dbh->do('DROP TABLE IF EXISTS changed');
	$dbh->do( qq{
		CREATE $createTemporary TABLE changed AS
			SELECT DISTINCT(scanned_dvd.url) AS url
			FROM   scanned_dvd
			JOIN   tracks ON (
				scanned_dvd.url = tracks.url
				AND tracks.`virtual` IS NULL
				AND tracks.content_type = 'fec'
				AND (
					tracks.timestamp IS NULL
					OR tracks.filesize IS NULL
					OR scanned_dvd.timestamp != tracks.timestamp
					OR scanned_dvd.filesize  != tracks.filesize
				)
			)
			WHERE  SUBSTR(scanned_dvd.url, 1, $baseLen) = $baseQuote
	} );
	my $changedSQL = 'SELECT url FROM changed';

	my $inDBOnlyCount    = _count($dbh, $inDBOnlySQL);
	my $onDiskOnlyCount  = _count($dbh, $onDiskOnlySQL);
	my $changedOnlyCount = _count($dbh, $changedSQL);

	my $changes = 0;

	$changes += $class->_processList($dbh, $next, $args, {
		name     => 'deleted DVD files',
		progress => 'PLUGIN_PLAYDVD_IMPORT_LIBRARY_DELETED',
		count    => $inDBOnlyCount,
		sql      => $inDBOnlySQL,
		handler  => \&_deleted,
	});

	$changes += $class->_processList($dbh, $next, $args, {
		name     => 'changed DVD files',
		progress => 'PLUGIN_PLAYDVD_IMPORT_LIBRARY_CHANGED',
		count    => $changedOnlyCount,
		sql      => $changedSQL,
		handler  => \&_changed,
	});

	$changes += $class->_processList($dbh, $next, $args, {
		name     => 'new DVD files',
		progress => 'PLUGIN_PLAYDVD_IMPORT_LIBRARY_NEW',
		count    => $onDiskOnlyCount,
		sql      => $onDiskOnlySQL,
		handler  => \&_new,
	});

	$dbh->do("DROP TABLE IF EXISTS $_") for qw(scanned_dvd dbonly diskonly changed);

	return $changes;
}

# Only one VOB file per folder is imported (see Formats::DVD::_doCheckFileSkip): drop
# the others from scanned_files, otherwise they would show up as "new" on every scan.
sub _keepFirstVOBPerFolder {
	my ($class, $dbh) = @_;

	my %first;
	my $urls = $dbh->selectcol_arrayref(q{SELECT url FROM scanned_files});
	foreach my $url (@$urls) {
		next unless $url =~ /\.vob$/i;
		my $dir = dirname($url);
		$first{$dir} = $url if !defined $first{$dir} || basename($url) lt basename($first{$dir});
	}

	my $sth = $dbh->prepare_cached('DELETE FROM scanned_files WHERE url = ?');
	foreach my $url (@$urls) {
		next unless $url =~ /\.vob$/i;
		$sth->execute($url) if $first{ dirname($url) } ne $url;
	}
}

sub _count {
	my ($dbh, $sql) = @_;
	my ($count) = $dbh->selectrow_array("SELECT COUNT(*) FROM ( $sql ) AS t1");
	return $count || 0;
}

# Synchronous equivalent of the core deleteTracks/updateTracks/addTracks: page through
# the list in chunks (avoids a long running read query, which would prevent WAL
# checkpoints) and call the handler for each url. Returns the number of items handled.
sub _processList {
	my ($class, $dbh, $next, $args, $details) = @_;

	my ($name, $total, $sql, $handler) = @$details{qw(name count sql handler)};

	$log->error("Processing $name ($total)") unless main::SCANNER && $main::progress;
	return 0 unless $total;

	my $progress;
	if ( $args->{progress} ) {
		$progress = Slim::Utils::Progress->new( {
			type  => 'importer',
			name  => $next . '|' . $details->{progress},
			bar   => 1,
			every => 0,
			total => $total,
		} );
	}

	my $done = 0;
	while ( $done < $total ) {
		my $urls = $dbh->selectcol_arrayref( $sql . ' ORDER BY url LIMIT ' . CHUNK_SIZE . ' OFFSET ' . $done );
		last unless $urls && @$urls;

		foreach my $url (@$urls) {
			if ( Slim::Music::Import->hasAborted() ) {
				$progress && $progress->final;
				return $done;
			}
			$progress && $progress->update( Plugins::PlayDVD::Utils::Misc::pathFromFileURL($url) );
			$handler->($url);
			$done++;
		}

		# Commit for every chunk when using scanner.pl
		main::SCANNER && Slim::Schema->forceCommit;
	}

	$progress && $progress->final;
	return $done;
}

sub _txn {
	my $work = shift;

	if ( Slim::Schema->dbh->{AutoCommit} ) {
		Slim::Schema->txn_do($work);
	}
	else {
		$work->();
	}
}

# Adds a DVD (main record + one virtual track per title). Slim::Utils::Scanner::Local::new
# filters on isSong, which is not true for the DVD main record, hence our own version.
sub _new {
	my $url = shift;

	main::INFOLOG && $log->is_info && $log->info("Handling new DVD $url");

	_txn( sub {
		Plugins::PlayDVD::Formats::DVD->getTag($url);
	} );
}

# Removes a DVD: main record and virtual title tracks, then lets contributors, albums,
# years and genres clean up what is no longer referenced (as Scanner::Local::deleted)
sub _deleted {
	my $url = shift;

	main::INFOLOG && $log->is_info && $log->info("Handling deleted DVD $url");

	my $dbh = Slim::Schema->dbh;

	_txn( sub {
		my $prefix = $url . '?title=';
		my $tracks = $dbh->selectall_arrayref(
			'SELECT id, album, year FROM tracks WHERE url = ? OR SUBSTR(url, 1, ?) = ?',
			{ Slice => {} }, $url, length($prefix), $prefix
		);
		return unless @$tracks;

		my $ids = join( ',', map { int $_->{id} } @$tracks );

		my $contribs = $dbh->selectcol_arrayref("SELECT DISTINCT(contributor) FROM contributor_track WHERE track IN ($ids)");
		my $genres   = $dbh->selectcol_arrayref("SELECT DISTINCT(genre) FROM genre_track WHERE track IN ($ids)");

		my (%seen, @albums, @years);
		@albums = grep { $_ && !$seen{"a$_"}++ } map { $_->{album} } @$tracks;
		@years  = grep { $_ && !$seen{"y$_"}++ } map { $_->{year} } @$tracks;

		$dbh->do("DELETE FROM contributor_track WHERE track IN ($ids)");
		$dbh->do("DELETE FROM genre_track WHERE track IN ($ids)");
		$dbh->do("DELETE FROM comments WHERE track IN ($ids)");
		$dbh->do("DELETE FROM tracks WHERE id IN ($ids)");

		Slim::Schema::Contributor->rescan($contribs) if @$contribs;
		Slim::Schema::Album->rescan(@albums)         if @albums;
		Slim::Schema::Year->rescan(@years)           if @years;
		Slim::Schema::Genre->rescan(@$genres)        if @$genres;
	} );
}

# A changed DVD is removed and imported again, the title list may have changed
sub _changed {
	my $url = shift;

	main::INFOLOG && $log->is_info && $log->info("Handling changed DVD $url");

	_deleted($url);
	_new($url);
}

1;
