package Plugins::PlayDVD::Importer;

use strict;
use warnings;

use Slim::Music::Import;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Plugins::PlayDVD::Utils::Misc;

use constant IS_SQLITE		=> (Slim::Utils::OSDetect->getOS()->sqlHelperClass() =~ /SQLite/ ? 1 : 0);
# Number of items to process at once, this value will affect the max size of the WAL file.
# Chunking is only required with SQLite, as we don't have this kind of concurrency problem with MySQL.
use constant CHUNK_SIZE		=> IS_SQLITE ? 50 : 1000;
use constant PENDING_NEW		=> 0x02;
my %pending = ();

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
	$log->debug("startScan " . Data::Dump::dump($class));	

	my $dirs  = shift || Slim::Utils::Misc::getMediaDirs();
	if (ref $dirs ne 'ARRAY' || scalar @{$dirs} == 0) {
		main::INFOLOG && $log->info("Skipping media folder scan - no folders defined.");
		$class->stillScanning(0);
		Slim::Music::Import->endImporter($class);
		return 0;
	}

	# get singledir parameter from the scanner if available
	my $singledir = main::SCANNER ? $ARGV[-1] : undef;
	my $count = 0;
	if ( ($dirs = Slim::Utils::Misc::getAudioDirs($singledir)) && scalar @{$dirs} ) {
		main::INFOLOG && $log->is_info && $log->info("Starting dvd-only scan");
		$log->debug("Scanning for DVDs in media dirs " . Data::Dump::dump($dirs));	       

		my $args	= {
			types    		=> 'dvd',
			scanName 		=> 'dvd',
			no_async 		=> 1,
			progress		=> 1,
			recursive		=> 1,
		};

		if ( ref $dirs ne 'ARRAY' ) {
			$dirs = [ $dirs ];
		}
		# get rid of empty entries in our $paths list
		$dirs 			= [ grep { $_ } @$dirs ];
		my $progress;
		my $changes = 0;
		
		$log->debug("Get count of DVD records in DB");
		my $DVDinDBSQL = qq{
			SELECT		url
			FROM		tracks
			WHERE 		url LIKE 'dvd://%'
		};	
		
		my $dbh 		= Slim::Schema->dbh;		
		my ($DVDonDiskCount) = $dbh->selectrow_array( qq{
			SELECT COUNT(*) FROM ( $DVDinDBSQL ) AS t1
		} );		
		$log->debug("Found $DVDonDiskCount DVD records in DB");						
		Slim::Utils::Scanner::Local->deleteTracks($dbh, \$changes, $dirs, "", {
			name  				=> 'existing DVD tracks from library',			# Used to display in scanner log with "Removing" as prefix
			count 				=> $DVDonDiskCount,
			progressName		=>  'PLUGIN_PLAYDVD_IMPORT_LIBRARY_DELETE',	# Used for progress bar description, requires entry in string.txt, with "_PROGRESS" suffix
			sql   				=> $DVDinDBSQL
		}, $args);	

		foreach my $next (@$dirs) {
			$next 			= Slim::Utils::Unicode::encode_locale($next);
			$next 			=~ s{/$}{};			
			$log->debug("Discovering DVD files in $next");
			# Delete records from temporary table
			my $dbh = Slim::Schema->dbh;
			$dbh->do("DELETE FROM scanned_files");			
			# Get list of files within this path
			Slim::Utils::Scanner::Local->find( $next, $args, sub {
				my $count		= shift;
				my $dbh 		= Slim::Schema->dbh;
				my $rows		= $dbh->selectall_arrayref(
					"SELECT * FROM scanned_files",
					{ Slice => {} }
				);								
				my $createTemporary = (main::DEBUGLOG && $log->is_debug) ? '' : 'TEMPORARY';
				#Files that are new and not in the database.
				$log->error("Build temporary table for new DVD files") unless main::SCANNER && $main::progress;
				$dbh->do('DROP TABLE IF EXISTS diskonly');
				$dbh->do( qq{
					CREATE $createTemporary TABLE diskonly AS
						SELECT          DISTINCT(url) AS url
						FROM            scanned_files
						WHERE           filesize != 0
				} );
				my $DVDonDiskOnlySQL = qq{
					SELECT url
					FROM   diskonly
				} . (IS_SQLITE ? '' : ' ORDER BY url');

				$log->debug("Get new DVD count") unless main::SCANNER && $main::progress;
				my ($DVDonDiskOnlyCount) = $dbh->selectrow_array( qq{
					SELECT COUNT(*) FROM ( $DVDonDiskOnlySQL ) AS t1
				} );					
				$class->addTracks($dbh, \$changes, $dirs, $next, $DVDonDiskOnlyCount, $DVDonDiskOnlySQL, $args);				
			} );
		}		
	}	
	Slim::Music::Import->endImporter($class);
}

# Re-create addTracks because 	Slim::Utils::Scanner::Local has hard coded texts that are not consistent for DVDs
sub addTracks {
	my ($class, $dbh, $changes, $paths, $nextFolder, $onDiskOnlyCount, $onDiskOnlySQL, $args) = @_;
	$log->error( "Scanning new DVD files ($onDiskOnlyCount)" ) unless main::SCANNER && $main::progress;

	if ( $onDiskOnlyCount && !Slim::Music::Import->hasAborted() ) {
		my $onDiskOnlySth;
		my $onDiskOnlyDone = 0;

		$pending{$nextFolder} |= PENDING_NEW;

		my $progress;
		if ( $args->{progress} ) {
			$progress = Slim::Utils::Progress->new( {
				type  => 'importer',
				name  => $nextFolder . '|' . 'PLUGIN_PLAYDVD_IMPORT_LIBRARY_NEW',				
				bar   => 1,
				every => ($args->{scanName} && $args->{scanName} eq 'playlist'), # record all playists in the db
				total => $onDiskOnlyCount,
			} );
		}

		my $new;
		my $handle_new = sub {
			if ( Slim::Utils::Scanner::Local->hasAborted($progress, $args->{no_async}) ) {
				$onDiskOnlySth && $onDiskOnlySth->finish;
				return 0;
			}

			# Page through the files, this is to avoid a long-running read query which
			# would prevent WAL checkpoints from occurring.
			if ( !$onDiskOnlySth ) {
				my $sql = $onDiskOnlySQL . " LIMIT $onDiskOnlyDone, " . CHUNK_SIZE;
				$onDiskOnlySth = $dbh->prepare_cached($sql);
				$onDiskOnlySth->execute;
				$onDiskOnlySth->bind_col(1, \$new);
			}

			if ( $onDiskOnlySth->fetch ) {
				$progress && $progress->update( Slim::Utils::Misc::pathFromFileURL($new) );
				$$changes++;
				$onDiskOnlyDone++;
				new($new);

				return 1;
			}
			else {
				my $more = 1;

				if ( !$onDiskOnlySth->rows ) {
					$dbh->do('DROP TABLE IF EXISTS diskonly');

					if ( !$args->{no_async} ) {
						$args->{paths} = $paths;
						Slim::Utils::Scanner::Local	->markDone( $nextFolder => PENDING_NEW, $$changes, $args );
					}

					$progress && $progress->final;
					$onDiskOnlySth->finish;
					$more = 0;
				}
				else {
					# Continue paging with the next chunk
					$onDiskOnlySth->finish;
					undef $onDiskOnlySth;
				}

				# Commit for every chunk when using scanner.pl
				main::SCANNER && Slim::Schema->forceCommit;

				return $more;
			}
		};

		if ( $args->{no_async} ) {
			while ( $handle_new->() ) { }
		}
		else {
			Slim::Utils::Scheduler::add_ordered_task( $handle_new );
		}
	}
}	

# Re-create sub new because Slim::Utils::Scanner::Local has filter on isSong (ie file of type "audio")
sub new {
	my $url = shift;

	my $work;
	if ( Plugins::PlayDVD::Utils::Misc::isDVD($url) ) {
		$work = sub {
			my $type					= Slim::Music::Info::typeFromPath($url);
			my $tagReaderClass		= "Plugins::PlayDVD::Formats::DVD";
			eval "use $tagReaderClass";
			if ( $@ ) {
				logError("Unable to load $tagReaderClass: $@");
				return {};
			}
		    my $tags 	= $tagReaderClass->getTag($url);		 
		};
	}
	
	if ( $work ) {
		if ( Slim::Schema->dbh->{AutoCommit} ) {
			Slim::Schema->txn_do($work);
		}
		else {
			$work->();
		}
	}
}
1;

