use v5.10;
use strict;
use warnings;
use feature ':5.10';

use LWP::UserAgent;
use List::MoreUtils qw{uniq};
use Encode;
use Carp;
use JSON;

binmode STDOUT, ":utf8";
# I'm gonna call 1.0 here, just because kovensky never had $VERSION.
our $VERSION = '1.0.1';
our %IRSSI = (
	authors		=> 'foxiepaws, Kovensky',
	contact		=> 'fox@foxiepa.ws',
	name		=> 'lastfm-bot',
	description	=> 'A lastfm bot',
);


Irssi::settings_add_str("lfmb", "lfmb_owner", $server->{nick});
Irssi::settings_add_str("lfmb", "lfmb_prefix", "-");

our $api_key = '4c563adf68bc357a4570d3e7986f6481';
our $owner = $server->{nick};
our $prefix = "-";
our $nick_user_map;
our $user_nick_map = {}; # derived from $nick_user_map
our $api_cache = {};
if( open my $cachefile, '<', $ENV{'HOME'}."/.irssi/lastfm_cache.json" ) {
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
	open my $cachefile, '>', $ENV{'HOME'}."/.irssi/lastfm_cache.json";
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
	my ($prevtime, $prevlen);
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
				$res{tags} = [grep { defined && !($_ ~~ ['touhou', 'anime']) } @{$res{tags}}[0..4]];
				pop @{$res{tags}} until @{$res{tags}} <= 4;

				$res{len}   = ($$info{track}{duration} // 0) / 1000; # miliseconds
				$res{loved} = $$info{track}{userloved};
				$res{count} = $$info{track}{userplaycount} if $$info{track}{userplaycount};
			} elsif ($$info{track}{duration} && $$_{date} && $$_{date}{uts}) {
				$prevlen  = $$info{track}{duration};
				$prevtime = $$_{date}{uts} - $prevlen;
			}
		}
		unless ($res{name}) {
			%res = (warn => "'$user' is not listening to anything right now. ". (@tracks < 1 || ref $tracks[0] ne 'HASH' ? "" :
			"The last played track is \x037\x02@{[_text $tracks[0]->{artist}]}\x03\x02 - \x037\x02$tracks[0]->{name}\x03\x02, back in @{[_text $tracks[0]->{date}]} UTC."));
		}

		my $now = time;
		if ($res{len} && $prevtime && ($now - $prevtime) <= $res{len}) {
			$res{pos} = $now - $prevtime;
			$res{pos} += $prevlen if $res{pos} < 0;
		}

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

	my $str = "'\x02$user\x02' is now playing: ";
	$str .= "\x037\x02$$data{artist}\x02\x03 - ";
	$str .= "\x037\x02$$data{album}\x02\x03 - " if $$data{album};
	$str .= "\x037\x02" . $$data{name} . "\x02\x03";
	if($$data{count}) {
		$str .= " [". ($$data{loved} ? "\x0304<3\x03 - " : "") ."playcount $$data{count}x]" ;
	}
	$str .= " (\x0310\x02". join( "\x02\x03, \x0310\x02", @{$$data{tags}} ) ."\x02\x03)" if $$data{tags} && @{$$data{tags}};
	$str .= " [\x037\x02";
	$str .= _secs_to_mins($$data{pos}) . "/" if $$data{pos};
	$str .= _secs_to_mins($$data{len}) . "\x02\x03]";
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
	my $onick = $server->{nick};
    if ($text =~ /$onick:np(:\w+)?/g) {
        my $additional = $1;
        $additional =~ s/://;
        send_msg($server, $target, now_playing($nick, 1,(0, $additional)));
    }

	given ($cmd[0]) {
		when ($prefix . 'np') { # now playing
			send_msg($server, $target, now_playing($nick, 1, @cmd));
			write_cache;
		}
		when ($prefix . 'wp') { # what's playing
			if ($nick eq $owner) {
				whats_playing($server, $target);
				write_cache;
			}
		}
		when ($prefix . 'compare') { # tasteometer comparison
			unless (@cmd > 1) { send_msg($server, $target, ".compare needs someone to compare to") }
			else {
				my @users = (@cmd[1,2]);
				unshift @users, $nick unless $cmd[2];
				map { $_ = nick_map $_ } @users[0,1];
				send_msg($server, $target, usercompare(@users));
			}
		}
		when ($prefix . 'setuser') {
			unless (@cmd > 1) { send_msg($server, $target, ".setuser needs a last.fm username") }
			elsif($cmd[1] eq $nick) { send_msg($server, $target, "$nick: You already are yourself") }
			else {
				my $username = $cmd[1];
				my $ircnick = $nick;
				if ($cmd[2]) {
					if ($nick eq $owner) {
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
		when ($prefix . 'deluser') {
			my $ircnick = $nick eq $owner ? ($cmd[1] // $nick) : $nick;
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
		when ($prefix . 'whois') {
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
        when ($prefix . 'source') {
            send_msg($server, $target, "source: https://github.com/foxiepaws/lastfm.pl");
        }
		when ($prefix . 'version') {
			send_msg($server, $target, "version: $VERSION - repo: https://github.com/foxiepaws/lastfm.pl");
		}
		when ($prefix . 'lastfm') {
	send_msg($server, $target, "$nick: help will be PMed to you, be patient as other users may have also used this function.");			
	my @help = (
'Commands that access last.fm use the IRC nickname unless associated through .setuser.',
'Unlike IRC, all names are CASE SENSITIVE.',
'Commands:',
"$prefix\x02np\x02 [username]     - shows your currently playing song, or of another user if specified",
"$prefix\x02compare\x02 u1 [u2]   - compares yourself with u1 (another user) if u2 isn't specified",
"                     compares u1 with u2 if both are given.",
"$prefix\x02setuser\x02 user      - associates the \"user\" last.fm username with your nickname.",
"                     the two argument form is only available to the owner.",
"$prefix\x02whois\x02 username    - given a last.fm username, return all nicknames that are associated to it.",
"$prefix\x02deluser\x02           - removes your last.fm association.",
"                     the form with argument is only available to the owner.",
"Owner-only commands:",
"$prefix\x02wp\x02                - shows everyone's currently playing song",
"$prefix\x02setuser\x02 nick user - associates the nick with the specified last.fm user",
"$prefix\x02deluser\x02 nick      - removes the nick's association with his last.fm account",
"$prefix\x02source\x02            - shows the source repo for the bot",
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
sub rehash_conf {
	$owner = Irssi::settings_get_str("lfmb_owner");
	$prefix = Irssi::settings_get_str("lfmb_prefix");
}

&rehash_conf();

Irssi::signal_add("setup changed",\&rehash_conf);
Irssi::signal_add_last("message public", \&message_public);
Irssi::signal_add_last("message own_public", \&message_own_public);
Irssi::command_bind('lfmb_reload', \&rehash_conf);
