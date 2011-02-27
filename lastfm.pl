use common::sense;
use LWP::UserAgent;
use List::MoreUtils qw{uniq};
use Encode;
use Carp;
use JSON;
use DBI;

binmode STDOUT, ":utf8";

our $api_key = '4c563adf68bc357a4570d3e7986f6481';

our $nick_user_map;
our $user_nick_map = {}; # derived from $nick_user_map
our $api_cache = {};
if( open my $cachefile, '<', 'lastfm_cache.json' ) {
	$api_cache = decode_json(scalar <$cachefile>);
	$nick_user_map = get_cache('mappings', 'nick_user');
	build_nick_map();
	close $cachefile;
}
$nick_user_map //= {};

sub build_nick_map {
	return unless $nick_user_map;
	for my $nick (keys %$nick_user_map) {
		next if $nick eq '#expire';
		my $user = $$nick_user_map{$nick};
		my $map = $$user_nick_map{$user} //= {};
		$$map{$nick} = 1;
	}
}

sub _delete_if_expired($$) {
	my ($hash, $key) = @_;
	return undef unless $hash && $key;
	my $item = $$hash{$key};
	return undef unless defined $item;

	# backwards compatibility
	delete $$hash{$key} && return undef unless $$item{'#expire'};

	if ($item && $$item{'#expire'} > 0 && $$item{'#expire'} < time) {
		delete $$hash{$key};
		return undef;
	}
	return $item;
}

sub clean_cache {
	for my $cache (values %$api_cache) {
		for (keys %$cache) {
			_delete_if_expired $cache, $_;
		}
	}
}

sub _text($) {
	my $tag = shift;
	return undef unless defined $tag;
	return $$tag{'#text'} if ref $tag;
	return $tag;
}

sub del_cache {
	croak "Insufficient arguments" unless @_ >= 2;
	my ($subcache, $key) = @_;
	die "Invalid cache $subcache" unless defined $subcache;
	$$api_cache{$subcache} //= {};
	delete $$api_cache{$subcache}{$key};
}

sub get_cache {
	croak "Insufficient arguments" unless @_ >= 2;
	my ($subcache, $key) = @_;
	die "Invalid cache $subcache" unless defined $subcache;
	my $cache = $$api_cache{$subcache} //= {};
	
	return undef unless defined $key;
	return _delete_if_expired $cache, $key;
}

sub upd_cache {
	my $cache = get_cache(@_);
	return $cache if $cache;
	return set_cache(@_);
}

sub set_cache {
	croak "Insufficient arguments" unless @_ >= 3;
	my ($subcache, $key, $value, $expire) = @_;
	die "Invalid cache $subcache" unless defined $subcache;
	my $cache = $$api_cache{$subcache} //= {};
	$expire //= 3600*24*7 * 10; # 1 week by default

	return undef unless defined $key;
	if( ref $value eq 'CODE' ) { # JSON can't store code; evaluate
		my @res = $value->();
		$value = @res > 1 ? [@res] : $res[0];
	}

	if( ref $value eq 'HASH' ) {
		$$cache{$key} = $value;
	} else {
		$$cache{$key} = { '#text' => $value };
	}

	if($expire > 0) {
		$$cache{$key}{'#expire'} = (time) + $expire;
	} else {
		$$cache{$key}{'#expire'} = -1;
	}

	return $$cache{$key};
}

sub write_cache {
	clean_cache;
	set_cache('mappings', 'nick_user', $nick_user_map, -1);
	open my $cachefile, '>', 'lastfm_cache.json';
	syswrite $cachefile, encode_json($api_cache);
	close $cachefile;
}

our $ua = LWP::UserAgent->new;
$ua->timeout(10);

our $prevreqtime;
our $lastreqtime;
our $reqcount = 0;

sub _clean($) {
	$_ = encode_utf8(shift);
	s/ /+/g;
	s/([^-A-Za-z0-9+])/%@{[sprintf "%2X", ord $1]}/g;
	return $_;
}

sub artist_gettoptags { # for artist.gettoptags API call
	my $res = shift;
	my $name = $$res{arid} ? $$res{arid} : $$res{artist};
	my $tag = 'artist.gettoptags';

	return upd_cache($tag, $name, sub {
		get_last_fm_data($tag, $$res{arid} ? 'mbid' : 'artist',  $name);
	});
}

sub get_last_fm_data {
	my $method = shift;
	my %params;
	if( $_[0] && ref $_[0] eq 'HASH' ) {
		%params = @{$_[0]};
	} else {
		my $_ = { @_ };
		%params = %$_;
	}

	my @paramary = map { join "=", _clean $_, _clean $params{$_} } keys %params;
	my $paramstr = scalar(@paramary) ? ("&". (join "&", @paramary)) : "";

	$lastreqtime = time;
	$prevreqtime //= $lastreqtime;
	sleep 1 if ($lastreqtime == $prevreqtime && $reqcount >= 5);
	if( $lastreqtime != $prevreqtime ) {
		$reqcount = 0;
	} else {
		$reqcount++;
	}
	my $resp = $ua->get("http://ws.audioscrobbler.com/2.0/?format=json&api_key=$api_key&method=$method$paramstr");
	return decode_json $resp->content if $resp->is_success;
	undef;
}

sub usercompare {
	my @user = @_[0,1];

	my $str = "'$user[0]' vs '$user[1]': ";
	my $data = get_last_fm_data( 'tasteometer.compare', type1 => 'user', type2 => 'user',
	                                                    value1 => $user[0], value2 => $user[1] );
	return "Error comparing $user[0] with $user[1]" unless $data && $$data{comparison}{result};
	my $res = $$data{comparison}{result};
	$str .= (sprintf "%2.1f", $$res{score} * 100) ."%";
	if( $$res{artists}{artist} && $$res{artists}{'@attr'}{matches} ) {
		$str .= " - Common artists include: ";
		$str .= join ", ", map { $$_{name} } (ref $$res{artists}{artist} eq 'ARRAY' ? @{$$res{artists}{artist}} : $$res{artists}{artist});
	}
	return $str;
}

sub get_user_np {
	my $user = shift;

	my %res;
	my $data = get_last_fm_data( 'user.getrecenttracks', limit => 1, user => $user );
	my $prevtime = -1;
	if( $data && (my $tracks = $$data{recenttracks}{track}) ) {
		my @tracks = (ref $tracks eq 'ARRAY' ? @$tracks : $tracks);
		for( @tracks ) {
			my $info = get_last_fm_data( 'track.getinfo', username => $user,
			                              $$_{mbid} ? 'mbid' : 'track', $$_{mbid} ? $$_{mbid} : $$_{name},
			           $$_{mbid} ? () : (artist => _text $$_{artist}));
			if( $$_{'@attr'}{nowplaying} ) {
				$res{name}   = $$_{name};
				$res{artist} = _text $$_{artist};
				$res{arid}   = $$_{artist}{mbid} if ref $$_{artist};
				$res{album}  = _text $$_{album} if $$_{album};
				$res{alid}   = $$_{album}{mbid} if ref $$_{album};
				$res{mbid}   = $$_{mbid} if $$_{mbid} && !ref $$_{mbid};

				my $tags = artist_gettoptags(\%res);
				$res{tags} = [map { $$_{name} } grep { $$_{count} } (ref $$tags{toptags}{tag} eq 'ARRAY' ? @{$$tags{toptags}{tag}} : $$tags{toptags}{tag})] if $tags;
				$res{tags} = [grep { defined } @{$res{tags}}[0..2]];

				$res{len}   = ($$info{track}{duration} // 0) / 1000; # miliseconds
				$res{loved} = $$info{track}{userloved};
				$res{count} = $$info{track}{userplaycount} if $$info{track}{userplaycount};
			} else {
				$prevtime = $$_{date}{uts} + $$info{track}{duration} / 1000 if $$info{track}{duration} && $$_{date} && $$_{date}{uts};
			}
		}
		unless ($res{name}) {
			%res = (warn => "'$user' is not listening to anything right now. ". (@tracks < 1 || ref $tracks[0] ne 'HASH' ? "" :
			"The last played track is @{[_text $tracks[0]->{artist}]} - $tracks[0]->{name}, back in @{[_text $tracks[0]->{date}]} UTC."));
		}

		my $now = time;
		$res{pos} = $now - $prevtime if $res{len} && $prevtime && (($now - $prevtime) <= $res{len});
	} else {
		%res = (error => "User '$user' not found or error accessing his/her recent tracks.");
	}
	return \%res;
}

sub _secs_to_mins {
	my $s = (shift);
	return sprintf "%02d:%02d", $s / 60, $s % 60;
}

sub format_user_np {
	my ($user, $data) = @_;

	my $str = "'$user' is now playing: ";
	$str .= "$$data{artist} - ";
	$str .= "$$data{album} - " if $$data{album};
	$str .= $$data{name};
	if($$data{count}) {
		$str .= " [". ($$data{loved} ? "<3 - " : "") ."playcount $$data{count}x]" ;
	}
	$str .= " (". join( ', ', @{$$data{tags}} ) .")" if $$data{tags} && @{$$data{tags}};
	$str .= " [";
	$str .= _secs_to_mins($$data{pos}) . "/" if $$data{pos};
	$str .= _secs_to_mins($$data{len}) . "]";
	return $str;
}

$SIG{INT} = sub { write_cache; exit };

sub send_msg {
	my ($server, $target, $text) = ($_[0], $_[1], join(' ', @_[2..$#_]));
	return unless defined $text && $text ne '';
	Irssi::timeout_add_once(50, sub { $server->command("MSG $target $text") }, undef);
}

sub nick_map($) {
	my $nick = shift;
	return $$nick_user_map{$nick} // $nick
}

sub now_playing {
	my ($nick, $ignerr, @cmd) = @_;
	my $user = $cmd[1] ? $cmd[1] : $nick;
	$user = nick_map $user;

	my $cached = get_cache('accountless', $user);
	return $ignerr ? _text $cached : undef if $cached;

	my $np = get_user_np($user);
	if ($$np{error}) {
		set_cache('accountless', $user, $$np{error});
		return $ignerr ? $$np{error} : undef;
	}
	elsif ($$np{warn}) { return $ignerr ? $$np{warn} : '' }
	else { return format_user_np($user, $np) }
}

sub whats_playing {
	my ($server, $target) = @_;
	my $chan = $server->channel_find($target);
	send_msg($server, $target, $_) for grep { defined && $_ ne '' }
	                                   map { now_playing($_, 0) } uniq
	                                   grep { !get_cache('accountless', $_) }
	                                   map { nick_map $$_{nick} } $chan->nicks;
}

sub message_public {
	my ($server, $text, $nick, $addr, $target) = @_;
	my @cmd = split /\s+/, $text;
	
	my $send = sub {
	};

	given ($cmd[0]) {
		when ('.np') { # now playing
			send_msg($server, $target, now_playing($nick, 1, @cmd));
			write_cache;
		}
		when ('.wp') { # what's playing
			if ($nick eq $server->{nick}) {
				whats_playing($server, $target);
				write_cache;
			}
		}
		when ('.compare') { # tasteometer comparison
			unless (@cmd > 1) { send_msg($server, $target, ".compare needs someone to compare to") }
			else {
				my @users = (@cmd[1,2]);
				unshift @users, $nick unless $cmd[2];
				map { $_ = nick_map $_ } @users[0,1];
				send_msg($server, $target, usercompare(@users));
			}
		}
		when ('.setuser') {
			unless (@cmd > 1) { send_msg($server, $target, ".setuser needs a last.fm username") }
			elsif($cmd[1] eq $nick) { send_msg($server, $target, "$nick: You already are yourself") }
			else {
				my $username = $cmd[1];
				my $ircnick = $nick;
				if ($cmd[2]) {
					if ($nick eq $server->{nick}) {
						$username = $cmd[2];
						$ircnick = $cmd[1];
					} else {
						send_msg($server, $target, "You can only associate your own nick. Use .setuser your_last_fm_username");
						return;
					}
				}
				my $data = get_last_fm_data( 'user.getrecenttracks', limit => 1, user => $username );
				if ($data && $$data{recenttracks}{track}) {
					send_msg($server, $target, "'$ircnick' is now associated with http://last.fm/user/$username");
					$$nick_user_map{$ircnick} = $username;
					$$user_nick_map{$username}{$ircnick} = 1;
					write_cache;
				} else {
					send_msg($server, $target, "Could not find the '$username' last.fm account");
				}
			}
		}
		when ('.deluser') {
			my $ircnick = $nick eq $server->{nick} ? ($cmd[1] // $nick) : $nick;
			my $username = $$nick_user_map{$ircnick};
			if ($username) {
				delete $$user_nick_map{$username}{$ircnick};
				delete $$nick_user_map{$ircnick};
				del_cache('accountless', $username) if get_cache('accountless', $username);
				send_msg($server, $target, "Removed the mapping for '$ircnick'");
				write_cache;
			} elsif (get_cache('accountless', $ircnick)) {
				del_cache('accountless', $ircnick);
				send_msg($server, $target, "Removed $ircnick from invalid account cache");
				write_cache;
			} else {
				send_msg($server, $target, "Mapping for '$ircnick' doesn't exist");
			}
		}
		when ('.whois') {
			unless (@cmd > 1) {
				send_msg($server, $target, ".whois needs a last.fm username");
				return;
			}
			my $user = $cmd[1];
			my $nick = $$nick_user_map{$user};
			if (my $map = $$user_nick_map{$user}) {
				my @nicks = sort keys %$map;
				my $end = pop @nicks;
				my $list = join ', ', @nicks;
				$list = $list ? "$list and $end" : $end;
				send_msg($server, $target, "$user is also known as $list");
			}
			elsif ($nick) {
				my $map = $$user_nick_map{$nick};
				my @nicks = sort grep { $_ ne $user and $_ ne $nick } keys %$map;
				my $end = pop @nicks;
				my $list = join ', ', @nicks;
				my $main = $list || $end ? " ($nick)" : "";
				$list = $end && $list ? "$list and $end" : $end ? $end : $list ? "" : $nick;
				send_msg($server, $target, "$user$main is also known as $list");
			}
			else {
				send_msg($server, $target, "$user is only known as $user");
			}
		}
		when ('.lastfm') {
			my @help = (
'Commands that access last.fm use the IRC nickname unless associated through .setuser.',
'Unlike IRC, all names are CASE SENSITIVE.',
'Commands:',
'.np [username]     - shows your currently playing song, or of another user if specified',
'.compare u1 [u2]   - compares yourself with u1 (another user) if u2 isn\'t specified',
'                     compares u1 with u2 if both are given.',
'.setuser user      - associates the "user" last.fm username with your nickname.',
'                     the two argument form is only available to the owner.',
'.whois username    - given a last.fm username, return all nicknames that are associated to it.',
'.deluser           - removes your last.fm association.',
'                     the form with argument is only available to the owner.',
'Owner-only commands:',
'.wp                - shows everyone\'s currently playing song',
'.setuser nick user - associates the nick with the specified last.fm user',
'.deluser nick      - removes the nick\'s association with his last.fm account',
);
			for (@help) {
				send_msg($server, $nick, $_);
			}
			send_msg($server, $target, "$nick: help PMed");
		}
		default {
			return;
		}
	}
}

sub message_own_public {
	my ($server, $text, $target) = @_;
	message_public( $server, $text, $server->{nick}, "localhost", $target );
}

Irssi::signal_add_last("message public", \&message_public);
Irssi::signal_add_last("message own_public", \&message_own_public);

package LastFM::Cache;
use common::sense;
use DBI;

sub new {
	my $self = bless {}, shift;
	my $dbname = shift // "lastfm_cache.db";

	my $dbh = $$self{dbh} =
		DBI->connect("dbi:SQLite:dbname=$dbname", '', '', { sqlite_unicode => 1 });
	$dbh->do("PRAGMA foreign_keys=ON");
	$dbh->do("PRAGMA locking_mode=EXCLUSIVE;");
	$dbh->do("PRAGMA journal_mode=WAL;");

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS usernames (uid INTEGER PRIMARY KEY, username TEXT UNIQUE, valid INTEGER);

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS nicknames (nickname TEXT UNIQUE, uid INTEGER NOT NULL,
	FOREIGN KEY (uid) REFERENCES usernames(uid));

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS artists (artid INTEGER PRIMARY KEY, artist TEXT UNIQUE, timestamp INTEGER);

	$dbh->do(<<'');
CREATE TABLE IF NOT EXISTS artist_tag_cache (artid INTEGER NOT NULL, tag TEXT NOT NULL, votes INTEGER,
	FOREIGN KEY (artid) REFERENCES artists(artid) ON DELETE CASCADE);

	$$self{prep} = {
		clean => {
			artists => $dbh->prepare(<<''), # ON DELETE CASCADE will do the Right Thing
DELETE FROM artists WHERE timestamp BETWEEN 1 AND ?;

			},
		get => {
			nicks_for_user  => $dbh->prepare(<<''),
SELECT nickname FROM nicknames NATURAL JOIN usernames WHERE lower(username) = lower(?);

			user_for_nick   => $dbh->prepare(<<''),
SELECT username FROM usernames NATURAL JOIN nicknames WHERE lower(nickname) = lower(?);

			uid_for_name    => $dbh->prepare(<<''),
SELECT uid FROM usernames NATURAL JOIN nicknames WHERE
	lower(?1) = lower(username) OR lower(?1) = lower(nickname);

			user_for_uid    => $dbh->prepare(<<''),
SELECT username FROM usernames WHERE uid = ?;

			nicks_for_uid   => $dbh->prepare(<<''),
SELECT nickname FROM nicknames WHERE uid = ?;

			valid_users     => $dbh->prepare(<<''),
SELECT username FROM usernames WHERE valid = 1;

			is_user_valid   => $dbh->prepare(<<''),
SELECT valid FROM usernames WHERE lower(username) = lower(?);

			tags_for_artist => $dbh->prepare(<<''),
SELECT tag FROM artist_tag_cache NATURAL JOIN artists WHERE
	lower(artist) = lower(?) ORDER BY votes;

			},
		add => {
			user       => $dbh->prepare(<<''),
INSERT INTO usernames (username, valid) VALUES (?, ?);

			nickname   => $dbh->prepare(<<''),
INSERT INTO nicknames (nickname, uid) VALUES
	(?, (SELECT uid FROM usernames WHERE lower(username) = lower(?)));

			artist     => $dbh->prepare(<<''),
INSERT INTO artists (artist, timestamp) VALUES (?, strftime('%s', 'now'));

			artist_tag => $dbh->prepare(<<''),
INSERT INTO artist_tag_cache (artid, tag, votes) VALUES
	((SELECT artid FROM artists WHERE lower(artist) = lower(?)), ?, ?);

			},
		update => {
			user_valid => $dbh->prepare(<<''),
UPDATE usernames SET valid = ? WHERE lower(username) = lower(?);

		},
		delete => {
			nickname         => $dbh->prepare(<<''),
DELETE FROM nicknames WHERE lower(nickname) = lower(?);

			orphan_usernames => $dbh->prepare(<<''),
DELETE FROM usernames WHERE uid NOT IN (SELECT uid FROM nicknames);

			},
		};

}

sub clean_cache {
	my $self = shift;
	my $now = time() - 3600*24*7*10;
	$$self{prep}{clean}{$_}->execute($now) for(keys %{$$self{prep}{clean}});
}

sub get_user_aliases {
	my($self, $query) = @_;
	my $get = $$self{prep}{get};
	my $uid = [$$get{uid_for_name}->execute($query)->fetchall_arrayref]->[0][0];
	return undef unless defined $uid;
	my @aliases;
	push @aliases, [$$get{user_for_uid}->execute($uid)->fetchall_arrayref]->[0][0];
	push @aliases, $$_[0] while ($_ = $$get{nicks_for_uid}->execute($uid)->fetch_arrayref);
	return @aliases;
}
