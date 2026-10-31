package Plugins::PlayDVD::Plugin;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::PlayDVD::Utils::Misc;
use Plugins::PlayDVD::Settings;
use Plugins::PlayDVD::PlayerSettings;

use Slim::Web::HTTP;
use HTTP::Status qw(RC_OK RC_FORBIDDEN);

use Scalar::Util qw(blessed);
use File::Spec::Functions qw(catdir catfile);
use Slim::Control::Queries;
use IPC::Open2;
use IO::Socket::INET;
use POSIX ();
use Time::HiRes ();
use JSON::XS;

my @srcfmts 		= ( 'dvd', 'iso');
my @targetfmts 		= ( 'flc', 'mp3', 'pcm', 'wav');

# Create log category
my $log = Slim::Utils::Log->addLogCategory({
    category     => 'plugin.playdvd',
    defaultLevel => 'INFO',
    description  => getDisplayName(),
});
use Slim::Utils::Misc;

my $prefs 	= preferences('plugin.playdvd');

# ------------------------------------------------------------------------------
# GLOBALS (file lexicals). Everything per-player lives in %ffmpegState.
#
# ------------------------------------------------------------------------------
my $BASE_DIR       = catdir(Slim::Utils::OSDetect::dirsFor('prefs'), 'PlayDVD');
my $LOG_DIR        = catdir($BASE_DIR, 'remote_players');
my $POLL_INTERVAL  = 1;                        # s between two tails of the report
my $MAX_INIT_TRIES = 20;                       # x 0.5 s waiting for the report file
my $MAX_PORT_TRIES = 100;                     # ports tried before giving up on finding a free one
my $ZMQ_TIMEOUT    = 2;                        # s, hard limit for one zmqsend call
my $ZMQ_TARGET     = 'Parsed_astreamselect_0'; # filter instance that receives "map"

my %ffmpegState;   # $mac (dash form) => state, see _reset_run() + _tail_report()
my $zmqBin;        # cached path of zmqsend

$prefs->init({
	'prefered_binary' 	=> "DVD-Transcode",
	'zmq_next_port'		=> 5555,
});
my $prefBinary		= $prefs->get('prefered_binary');

sub initPlugin {
	my $class = shift;

	my $version = $class->_pluginDataFor('version') || 'unknown';
	$log->info("Initializing PlayDVD plugin $version");

	Slim::Player::ProtocolHandlers->registerHandler(
		dvd => 'Plugins::PlayDVD::ProtocolHandler'
	);

	Slim::Web::Pages->addPageFunction("/transcode.log", \&log_handler);
	Slim::Web::Pages->addPageFunction("plugins/PlayDVD/ffmpeg/init", \&ffmpeg_init_handler);
	Slim::Web::Pages->addPageFunction("plugins/PlayDVD/ffmpeg/astreamselect", \&ffmpeg_astreamselect_handler);

	Plugins::PlayDVD::Settings->new($class);
	Plugins::PlayDVD::PlayerSettings->new;
	_overrideRemoteCheck();
	_registerFormatHandler();
	_init_Prefs();
	_init_LyrionEvents();
	$class->SUPER::initPlugin(@_);
}

sub pluginDir { shift->_pluginDataFor('basedir') }

sub shutdownPlugin {
	my $class = shift;
	$log->info("Shutting down PlayDVD plugin");

	Slim::Control::Request::unsubscribe(\&initClient);
	Slim::Control::Request::unsubscribe(\&playlistNewSong);
	Slim::Control::Request::unsubscribe(\&playlistPause);
	Slim::Control::Request::unsubscribe(\&playlistStop);
	Slim::Control::Request::unsubscribe(\&playlistOpen);

	stop_ffmpeg_events($_) for Slim::Player::Client::clients();
}

sub getDisplayName { 'PLUGIN_PLAYDVD' }


sub _registerFormatHandler {
    Slim::Formats->init();
    $Slim::Formats::tagClasses{dvd} ||= 'Plugins::PlayDVD::Formats::DVD';
    $Slim::Formats::tagClasses{iso} ||= 'Plugins::PlayDVD::Formats::DVD';
    $Slim::Formats::tagClasses{vob} ||= 'Plugins::PlayDVD::Formats::DVD';
    return 1;
}

sub log_handler {
    my ($client, $params, undef, $httpClient, $response) = @_;
    my $mac	= Plugins::PlayDVD::Utils::Misc->mac($client);
    my $logFile = catfile($LOG_DIR, $mac, 'transcode.log');
    return Slim::Web::Pages::Common->logFileViewer($client, $params, $httpClient, $response, $logFile);
}

# Slim::Control::Queries::_notLocalTrackAndRemoteUrl() is private and decides whether
# getMetadataFor() is used for a track. Wrap it so dvd:// tracks stored in the DB
# (Slim::Schema::Track) also take the remote-metadata path.
sub _overrideRemoteCheck {
	my $orig = Slim::Control::Queries->can('_notLocalTrackAndRemoteUrl');

	if (!$orig) {
		$log->warn('Slim::Control::Queries::_notLocalTrackAndRemoteUrl not found - LMS changed? Override skipped.');
		return;
	}

	no warnings 'redefine';
	no strict 'refs';

	*{'Slim::Control::Queries::_notLocalTrackAndRemoteUrl'} = sub {
		my $track = $_[0];

		if (ref $track && blessed($track) && $track->can('url')) {
			my $url = $track->url;
			return 1 if defined $url && $url =~ m{^dvd://}i;
		}

		return $orig->(@_);
	};

	main::INFOLOG && $log->is_info && $log->info('Installed dvd:// remote-track override');
}

sub _init_Prefs {
	foreach my $srcfmt (@srcfmts) {
		foreach my $targetfmt (@targetfmts) {
			my $rule 	= $srcfmt . '-' . $targetfmt . '-*-*';
			my $transcode 	= $Slim::Player::TranscodingHelper::commandTable{$rule};
			$transcode 	=~ s/\[.*?\]/\[$prefBinary\]/;
			$Slim::Player::TranscodingHelper::commandTable{$rule} = $transcode;
			}
		}
## Store server IP and port in file
	mkdir($BASE_DIR, 0755) unless (-d $BASE_DIR);
	my $serverAddress	= Slim::Utils::Network::serverAddr();
	my $serverPort		= preferences('server')->get('httpport');
	my $jsonrpc		= 'http://' . $serverAddress . ':' . $serverPort . '/jsonrpc.js';
	my $jsonrpcPath 	= catfile($BASE_DIR, 'jsonrpc');
	if ( open(my $handle, ">", $jsonrpcPath) ) {
		print $handle $jsonrpc;
		close($handle);
	}
	else {
		$log->error("Cannot write $jsonrpcPath: $!");
	}
}

sub initClient {
	my $request 	= shift;
	my $client 		= $request->client() || return;
	$log->info("Initializing client " . $request->client()->macaddress);
	_init_ClientConfig($client);
}

# True if nobody listens on 127.0.0.1:$port and no other player has it assigned
sub _zmq_port_available {
	my ($client, $port) = @_;

	for my $other ( Slim::Player::Client::clients() ) {
		next if $other->id eq $client->id;
		my $assigned = $prefs->client($other)->get('zmq_port') || '';
		return 0 if $assigned =~ /:\Q$port\E$/;
	}

	# a successful listen proves the port is free (closed again right away)
	my $sock = IO::Socket::INET->new(
		Listen    => 1,
		LocalAddr => '127.0.0.1',
		LocalPort => $port,
		Proto     => 'tcp',
		ReuseAddr => 1,
	);
	return $sock ? 1 : 0;
}

sub _init_ClientConfig {
	my ($client) 	= @_;
	my $mac			= Plugins::PlayDVD::Utils::Misc->mac($client);
	# For each client create or update preferences:
	### 1) FFMPEG		: zmq_host,	zmq_port
	### 2) VLC HTTP LUA	: lua_http_host, lua_http_port, lua_http_password
	### 3) MPV IPC		: ipc_server
    my $zmq_port;
	$zmq_port 	= $prefs->client($client)->get('zmq_port');
	if ( !$zmq_port ) {
	    # Get global counter, default to base_port
	    my $next_port = $prefs->get('zmq_next_port');
	    # Skip ports that are used by another process or already assigned to another player
	    my $tries = 0;
	    while ( $tries++ < $MAX_PORT_TRIES && !_zmq_port_available($client, $next_port) ) {
	        $log->warn("zmq port $next_port is not available, trying next");
	        $next_port++;
	    }
	    # Assign port to this client
	    $zmq_port   = "tcp://127.0.0.1:" . $next_port;
	    $prefs->client($client)->set('zmq_port', $zmq_port);
	    # Increment global counter for next client
	    $prefs->set('zmq_next_port', $next_port + 1);
	}
}

sub _init_LyrionEvents {
	Slim::Control::Request::subscribe(\&initClient, [['client'],['new','reconnect']]);
	Slim::Control::Request::subscribe(\&playlistNewSong, [['playlist'],['newsong']]);
	Slim::Control::Request::subscribe(\&playlistPause, [['playlist'],['pause']]);
	Slim::Control::Request::subscribe(\&playlistStop, [['playlist'],['stop','clear']]);
	Slim::Control::Request::subscribe(\&playlistOpen, [['playlist'],['open']]);
	$log->debug("  Subscribe to Lyrion events... Done");
}

sub playlistStop {
	my $request 	= shift;
	my $client 		= $request->client() || return;
	my $mac			= Plugins::PlayDVD::Utils::Misc->mac($client);
	$log->debug("playlistStop");
	Slim::Utils::Timers::killTimers($client, \&poll_ffmpeg_events);
	$log->debug("Killing timer polling Ffmpeg events on client " . Data::Dump::dump($client->macaddress));
	stop_ffmpeg_events($client);
}

sub playlistPause {
	my $request 	= shift;
	my $client 		= $request->client() || return;
	my $mac			= Plugins::PlayDVD::Utils::Misc->mac($client);
	$log->debug("playlistPause");
}

sub playlistOpen {
	my $request 	= shift;
	my $client 		= $request->client() || return;
	my $mac			= Plugins::PlayDVD::Utils::Misc->mac($client);
	$log->debug("playlistOpen");
}

sub playlistNewSong {
	my $request = shift;            # Slim::Control::Request object
    # client object (may be undef for global notifications)
	my $client 		= $request->client() || return;

	my $song 			= $client->playingSong() || return;
	my $track 		= $song->currentTrack();
	my $url 			= $track->url;
	if ( $url !~ /^dvd:\/\// ) {
		# moved on to a non DVD track: no need to keep polling the previous report
		stop_ffmpeg_events($client);
		return;
	}

	my $mac			= Plugins::PlayDVD::Utils::Misc->mac($client);
	$log->debug("playlistNewSong");
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 1, \&init_ffmpeg_events, $client);
}

# ------------------------------------------------------------------------------
# Small helpers
# ------------------------------------------------------------------------------
sub _mac {
	my ($client) = @_;
	return Plugins::PlayDVD::Utils::Misc->mac($client);
}

sub _report_path {
	my ($mac) = @_;
	return catfile($BASE_DIR, 'remote_players', $mac, 'ffmpeg-report.log');
}

# $player = "aa:bb:cc:dd:ee:ff" as sent by the UI -> ($client, $mac)
sub _resolve_player {
	my ($player) = @_;
	return unless defined $player && length $player;
	my $client = Slim::Player::Client::getClient(lc $player);
	my $mac    = $client ? _mac($client) : (lc $player) =~ s/:/-/gr;
	return ($client, $mac);
}

sub _send_json {
	my ($httpClient, $httpResponse, $data) = @_;
	my $json = encode_json($data);
	$httpResponse->code(RC_OK);
	$httpResponse->content_type('application/json');
	$httpResponse->content_length(length($json));
	Slim::Web::HTTP::addHTTPResponse($httpClient, $httpResponse, \$json, undef, undef);
}

# Forget everything learned from the previous ffmpeg run (file bookkeeping kept)
sub _reset_run {
	my ($st) = @_;
	my $run = ($st->{run} // 0) + 1;
	delete @$st{qw(in_input ready switchable current started from format
	               duration bitrate input_start)};
	$st->{chapters} = [];
	$st->{video}    = [];
	$st->{audio}    = [];     # position in this list == astreamselect input index
	$st->{run}      = $run;   # lets the UI ignore data of a previous run
}

# ------------------------------------------------------------------------------
# Life cycle: start on Playlist New Song (DVD tracks only), stop otherwise
# ------------------------------------------------------------------------------
sub init_ffmpeg_events {
	my ($client, $tries) = @_;
	$tries ||= 0;
	my $mac = _mac($client) or return;

	# never more than ONE pending timer chain per player
	Slim::Utils::Timers::killTimers($client, \&init_ffmpeg_events);
	Slim::Utils::Timers::killTimers($client, \&poll_ffmpeg_events);

	if (-e _report_path($mac)) {
		$log->debug("init_ffmpeg_events: polling $mac");
		poll_ffmpeg_events($client);
	} elsif ($tries < $MAX_INIT_TRIES) {
		Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.5,
		                              \&init_ffmpeg_events, $tries + 1);
	} else {
		$log->debug("init_ffmpeg_events: no report for $mac, giving up");
	}
}

# Call when the player stops / clears the playlist / plays a non-DVD track
sub stop_ffmpeg_events {
	my ($client) = @_;
	my $mac = _mac($client) or return;
	Slim::Utils::Timers::killTimers($client, \&init_ffmpeg_events);
	Slim::Utils::Timers::killTimers($client, \&poll_ffmpeg_events);
	my $st = delete $ffmpegState{$mac};
	close $st->{fh} if $st && $st->{fh};
}

sub poll_ffmpeg_events {
	my ($client) = @_;
	my $mac = _mac($client) or return;
	Slim::Utils::Timers::killTimers($client, \&poll_ffmpeg_events);
	_tail_report($mac);
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $POLL_INTERVAL,
	                              \&poll_ffmpeg_events);
}

# Read the next poll soon (e.g. right after a "map" command), keeping one chain
sub _poll_soon {
	my ($client, $delay) = @_;
	Slim::Utils::Timers::killTimers($client, \&poll_ffmpeg_events);
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $delay,
	                              \&poll_ffmpeg_events);
}

# ------------------------------------------------------------------------------
# Incremental reader. Handles: file not there yet, new inode, truncation +
# rewrite by a new run (first line differs), and half-written last lines.
# ------------------------------------------------------------------------------
sub _tail_report {
	my ($mac) = @_;
	my $path = _report_path($mac);
	my @s    = stat($path) or return;                      # no file: keep state

	my $st = $ffmpegState{$mac} ||= do { my %new; _reset_run(\%new); \%new };

	if (!$st->{fh} || ($st->{ino} // 0) != $s[1]) {         # first time / file replaced
		close $st->{fh} if $st->{fh};
		open(my $fh, '<', $path) or do { $log->error("Cannot open $path: $!"); return };
		@$st{qw(fh ino pos head)} = ($fh, $s[1], 0, undef);
	}
	my $fh = $st->{fh};

	# same inode, but is it still the same run?  (the helper truncates at start)
	seek($fh, 0, 0);
	my $head = <$fh>;
	return unless defined $head && $head =~ /\n\z/;         # empty / partial: wait
	if (defined $st->{head} && ($head ne $st->{head} || $s[7] < $st->{pos})) {
		$st->{pos} = 0;                                     # new run: re-read from top
	}
	$st->{head} = $head;

	seek($fh, $st->{pos}, 0);
	while (defined(my $line = <$fh>)) {
		last unless $line =~ /\n\z/;                        # half-written line: next poll
		$st->{pos} = tell($fh);
		_handle_ffmpeg_event($mac, $line);
	}
}

# ------------------------------------------------------------------------------
# Parser: one report line in, state updated, notification when something the
# UI cares about changed
# ------------------------------------------------------------------------------
sub _handle_ffmpeg_event {
	my ($mac, $events) = @_;
	my $st = $ffmpegState{$mac} or return;

	for my $line (split /[\r\n]+/, $events) {
		next unless $line =~ /\S/;

		# the "Input #" dump is made of indented lines; first non-indented line ends it
		$st->{in_input} = 0 if $st->{in_input} && $line !~ /^\s/;

		if    ($line =~ /^ffmpeg started on/)  { _event_log_start($st, $line) }
		elsif ($line =~ /^Input #/)            { _event_log_input($st, $line) }
		elsif ($st->{in_input}) {
			if    ($line =~ /^  Duration:/)    { _event_log_duration($st, $line) }
			elsif ($line =~ /^    Chapter #/)  { _event_log_chapter($st, $line) }
			elsif ($line =~ /^  Stream #/)     { _event_log_stream($st, $line) }
		}
		elsif ($line =~ /^Stream mapping:/)    { _event_log_ready($st, $mac) }
		elsif ($line =~ /^\[Parsed_astreamselect_\d+ @ [^\]]+\] Map input stream (\d+) to output stream 0/) {
			_event_log_astreamselect($st, $mac, $1);
		}
	}
}

sub _event_log_start {
	my ($st, $line) = @_;
	_reset_run($st) if defined $st->{started};      # a second run in the same file
	$st->{started} = $line;
}

sub _event_log_input {
	my ($st, $line) = @_;
	return if defined $st->{from};                   # only the first input matters
	my ($input, $format, $from) = $line =~ /^Input #(\d+),\s*([^,]+),\s*from\s+'(.*)'/ or return;
	@$st{qw(format from)} = ($format, $from);
	$st->{in_input} = 1;
}

sub _event_log_duration {
	my ($st, $line) = @_;
	my ($duration, $start, $bitrate) =
		$line =~ /^\s*Duration:\s*([^,]+),\s*start:\s*([^,]+),\s*bitrate:\s*(.*)$/ or return;
	@$st{qw(duration input_start bitrate)} = ($duration, $start, $bitrate);
}

sub _event_log_chapter {
	my ($st, $line) = @_;
	my ($chapter, $start, $end) =
		$line =~ /^\s*Chapter #([^:]+:[^:]+):\s*start\s+([^,]+),\s*end\s+(.+)$/ or return;
	push @{$st->{chapters}}, { chapter => $chapter, start => $start + 0, end => $end + 0 };
}

sub _event_log_stream {
	my ($st, $line) = @_;
	my ($stream, $id, $language, $type, $properties) =
		$line =~ /^\s*Stream #(\d+:\d+)\[([^\]]+)\](?:\(([^)]+)\))?:\s*(Video|Audio):\s*(.*)$/
		or return;
	my $entry = { stream => $stream, id => $id, language => $language, properties => $properties };
	if (lc $type eq 'audio') {
		$entry->{index} = scalar @{$st->{audio}};    # == astreamselect input number
		push @{$st->{audio}}, $entry;
	} else {
		push @{$st->{video}}, $entry;
	}
}

# "Stream mapping:" is printed once the graph is configured: azmq is bound
sub _event_log_ready {
	my ($st, $mac) = @_;
	$st->{ready} = 1;
	$st->{current} //= 0 if @{$st->{audio}};         # no filter graph: single stream
	_event_notify($mac);
}

# Printed at start and after every "map" command ffmpeg actually applied
sub _event_log_astreamselect {
	my ($st, $mac, $index) = @_;
	$st->{switchable} = 1;
	return if defined $st->{current} && $st->{current} == $index;
	$st->{current} = $index + 0;
	$log->debug("audio stream $index active for $mac");
	_event_notify($mac);
}

# ------------------------------------------------------------------------------
# What the UI gets (init handler + notifications). No filehandles, no internals.
# ------------------------------------------------------------------------------
sub _public_state {
	my ($mac) = @_;
	my $st = $ffmpegState{$mac} or return { ready => \0 };
	return {
		run        => $st->{run},
		ready      => $st->{ready}      ? \1 : \0,
		switchable => $st->{switchable} ? \1 : \0,
		started    => $st->{started},
		from       => $st->{from},
		format     => $st->{format},
		duration   => $st->{duration},
		bitrate    => $st->{bitrate},
		chapters   => $st->{chapters},
		video      => $st->{video},
		audio      => $st->{audio},
		current    => $st->{current},            # index into audio[]
	};
}

sub _event_notify {
	my ($mac) = @_;
	my $st = $ffmpegState{$mac};
	return unless $st && $st->{ready};               # nothing useful before the dump is parsed
	my $notify_list = [
		{
		  player => $mac,
		  type   => 'PlayDVD',
		  data   => _public_state($mac),
		}
	];
	Slim::Control::Request::notifyFromArray($notify_list);
}

# ------------------------------------------------------------------------------
# Web handlers (same names as before)
# ------------------------------------------------------------------------------
sub ffmpeg_init_handler {
	my ($client, $params, $callback, $httpClient, $httpResponse) = @_;

	my ($c, $mac) = _resolve_player($params->{player});
	my $data;
	if (!$mac || ($params->{cmd} // '') ne 'init') {
		$data = { error => 'bad request' };
	} else {
		# plugin restarted / UI opened late: attach now
		init_ffmpeg_events($c) if $c && !$ffmpegState{$mac};
		$data = _public_state($mac);
	}
	_send_json($httpClient, $httpResponse, $data);
}

sub ffmpeg_astreamselect_handler {
	my ($client, $params, $callback, $httpClient, $httpResponse) = @_;

	my $map  = $params->{map};
	my $data = { ok => \0, error => 'bad request' };
	if (($params->{cmd} // '') eq 'astreamselect' && defined $map && $map =~ /^\d+$/) {
		$data = _set_audio_stream($params->{player}, $map + 0);
	}
	_send_json($httpClient, $httpResponse, $data);
}

# Ask ffmpeg to switch; the new "current" is NOT set here: it is set when the
# "Map input stream" line shows up in the report (= ffmpeg really applied it).
sub _set_audio_stream {
	my ($player, $map) = @_;

	my ($client, $mac) = _resolve_player($player);
	return { ok => \0, error => 'unknown player' } unless $client;

	my $st = $ffmpegState{$mac};
	return { ok => \0, error => 'no active DVD stream' }
		unless $st && $st->{ready} && $st->{switchable};
	return { ok => \0, error => 'invalid audio stream' } if $map >= @{$st->{audio}};

	my $endpoint = $prefs->client($client)->get('zmq_port');   # the player's assigned port
	return { ok => \0, error => 'no zmq endpoint' } unless $endpoint;

	my ($status, $message) = _zmq_send($endpoint, $ZMQ_TARGET, 'map', $map);
	my $ok = (defined $status && $status == 0) ? 1 : 0;
	$log->debug("zmq map $map for $mac -> " . ($status // 'undef') . " " . ($message // ''));

	_poll_soon($client, 0.15) if $ok;                       # read the confirmation right away

	return {
		ok        => $ok ? \1 : \0,
		status    => $status,
		message   => $message,
		requested => $map,
		current   => $st->{current},
		run       => $st->{run},
		timestamp => POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
	};
}

# One zmqsend call: no shell, hard timeout, returns ($status, $message)
# e.g. (0, "Success"). On failure: (undef, "reason").
# NOTE: still blocks the LMS loop for up to $ZMQ_TIMEOUT s in the worst case.
sub _zmq_send {
	my ($endpoint, $target, $command, $arg) = @_;

	$zmqBin ||= Slim::Utils::Misc::findbin('zmqsend');
	if ( !$zmqBin ) {
		$zmqBin = qx(find /config/ -type f -name "zmqsend");
		chomp $zmqBin;
	}
	if ( !$zmqBin ) {
		return (undef, 'zmqsend not found');
	}

	local $SIG{PIPE} = 'IGNORE';
	my ($out, $in);
	my $pid = eval { open2($out, $in, 'timeout', $ZMQ_TIMEOUT, $zmqBin, '-b', $endpoint) };
	return (undef, "cannot run zmqsend: " . ($@ || $!)) unless $pid;

	print {$in} "$target $command $arg\n";
	close $in;
	my $reply = <$out>;
	close $out;
	waitpid($pid, 0);

	return (undef, 'no reply (timeout?)') unless defined $reply;
	chomp $reply;
	return ($reply =~ /^(-?\d+)\s*(.*)$/) ? ($1 + 0, $2) : (undef, $reply);
}

# ------------------------------------------------------------------------------
# PUBLIC API for other packages (e.g. the protocol handler).
# %ffmpegState is a file lexical on purpose: nobody else can touch the filehandles
# and offsets in it. Other packages call this instead:
#
#   my $info = Plugins::PlayDVD::Plugin::currentAudioInfo($client) or ...;   # <- your package name
#   $info->{text}   "AC3 5.1, 48 kHz, 448 kb/s"
#
# Returns undef while there is nothing reliable to show (not attached yet,
# graph not up, no audio stream) so the caller can decide what to display.
# Pure in-memory lookup: cheap enough to call on every metadata request.
# ------------------------------------------------------------------------------
my %LANG_NAME = (
	eng => 'English',   fre => 'French',    fra => 'French',    ger => 'German',
	deu => 'German',    spa => 'Spanish',   ita => 'Italian',   por => 'Portuguese',
	dut => 'Dutch',     nld => 'Dutch',     swe => 'Swedish',   nor => 'Norwegian',
	dan => 'Danish',    fin => 'Finnish',   pol => 'Polish',    cze => 'Czech',
	ces => 'Czech',     hun => 'Hungarian', rus => 'Russian',   jpn => 'Japanese',
	chi => 'Chinese',   zho => 'Chinese',   kor => 'Korean',    ara => 'Arabic',
	heb => 'Hebrew',    gre => 'Greek',     ell => 'Greek',     tur => 'Turkish',
);

sub currentAudioInfo {
	my ($client) = @_;
	return unless $client;
	my $mac = _mac($client) or return;
	my $st  = $ffmpegState{$mac} or return;
	return unless $st->{ready} && defined $st->{current};
	my $a = $st->{audio}[ $st->{current} ] or return;

	# "ac3, 48000 Hz, 5.1(side), fltp, 448 kb/s"
	my @p = map { my $x = $_; $x =~ s/^\s+|\s+$//g; $x } split /,/, ($a->{properties} // '');
	my $codec  = $p[0] // '';
	my ($hz)   = map { /^(\d+)\s*Hz$/    ? $1 : () } @p;
	my ($kbps) = map { /^(\d+)\s*kb\/s$/ ? $1 : () } @p;
	my $layout = $p[2] // '';
	$layout    =~ s/\(.*\)//;                                  # "5.1(side)" -> "5.1"
	$layout    = '' if $layout =~ /Hz$|kb\/s$/;

	my $code = $a->{language};
	my $lang = $code ? ($LANG_NAME{lc $code} // uc $code) : '';

	my $text = join(', ', grep { length }
		join(' ', grep { length } $codec, $layout),
		(defined $hz   ? sprintf('%g kHz', $hz / 1000) : ''),
		(defined $kbps ? "$kbps kb/s"                  : ''),
	);

	return {
		index      => $st->{current},
		count      => scalar @{ $st->{audio} },
		language   => $lang,                                   # '' when the disc has no tag
		codec      => $codec,
		channels   => $layout,
		samplerate => $hz,                                     # Hz, undef if unknown
		bitrate    => $kbps,                                   # kbit/s, undef if unknown
		text       => $text,                                   # "AC3 5.1, 48 kHz, 448 kb/s"
		label      => ($st->{current} + 1) . '/' . scalar(@{ $st->{audio} })
		              . ' ' . ($lang || 'Audio') . ' - ' . $text,   # "2/3 French - AC3 5.1, ..."
	};
}

1;

