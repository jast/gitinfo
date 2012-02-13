#!/usr/bin/perl
package BotIrc;

use common::sense;
use JSON;
use File::Slurp;
use POE;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::NickServID;
use POE::Component::Client::DNS;
use POE::Component::Server::TCP;
use POE::Filter::Line;
use Socket;
use Socket6;

use lib '.';
use control;
use db;
use plugin;

our $config;
our $config_file = 'config.json';
	$config_file = $ARGV[0] if (defined($ARGV[0]) && -f $ARGV[0]);
our $kernel;
our %heap;

my %handlers = ();

sub read_config {
	$config = read_file($config_file) or fatal("Config file `$config_file' missing: $!");
	$config = decode_json($config);
}
read_config();

sub msg {
	print STDERR "[".localtime."] ".shift."\n";
}
sub info { msg("[INFO]    ".shift); }
sub warn { msg("[WARNING] ".shift); }
sub error { msg("[ERROR]   ".shift); }
sub fatal { msg("[FATAL]   ".shift); exit(1); }

BotDb::init();
BotCtl::init();
BotPlugin::init();

our $irc = POE::Component::IRC::State->spawn(
	'alias'		=> "IRC",
	'Server'	=> $config->{server},
	'Port'		=> ($config->{port} // 6667),
	'Nick'		=> $config->{nick},
	'Username'	=> $config->{username},
	'Ircname'	=> $config->{realname},
	'LocalAddr'	=> $config->{local_addr},
	'useipv6'	=> $config->{ipv6},
	'Raw'		=> 1,
);

if ($config->{control_enabled}) {
	POE::Component::Server::TCP->new(
		Address		=> $config->{control_addr},
		Domain		=> $config->{control_ipv6} ? AF_INET6 : AF_INET,
		Alias		=> "ControlServer",
		Port		=> $config->{control_port},
		Started		=> sub { info "Control server started."; },
		ClientFilter	=> POE::Filter::Line->new(Literal => "\012"),
		ClientConnected	=> \&BotCtl::on_connected,
		ClientDisconnected	=> \&BotCtl::on_disconnected,
		ClientInput	=> \&BotCtl::on_input,
	);
}

our $session = POE::Session->create(
	inline_states => {
		_start	=> \&main_start,
	},
	heap => {
		irc => $irc,
	},
);

sub main_start {
	$kernel = $_[KERNEL];
	if (ref($config->{channel}) eq '') {
		$config->{channel} = [$config->{channel}];
	}
	my %chans;
	$chans{lc $_} = undef for @{$config->{channel}};
	$config->{channel} = \%chans;
	$irc->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new(Channels => \%chans));
	$irc->plugin_add('Connector', POE::Component::IRC::Plugin::Connector->new());
	$irc->plugin_add('NickServID', POE::Component::IRC::Plugin::NickServID->new(Password => $config->{nick_pwd})) if defined $config->{nick_pwd};
	add_handler('irc_socketerr', 'core', sub {
		error("IRC: socket error while connecting: ". $_[ARG0]);
		return 0;
	});
	add_handler('irc_error', 'core', sub {
		warn("IRC: general error: ". $_[ARG0]);
		return 0;
	});
	add_handler('irc_connected', 'core', sub {
		info("IRC: connected to ". $_[ARG0]);
		return 0;
	});
	add_handler('irc_disconnected', 'core', sub {
		warn("IRC: disconnected from ". $_[ARG0]);
		return 0;
	});
	add_handler('irc_public', 'core', \&on_irc_public);
	add_handler('irc_msg', 'core', \&on_irc_msg);
	for (@{$config->{autoload_plugins}}) {
		BotPlugin::load($_);
	}
	$irc->yield(register => 'all');
	$irc->yield(connect => {});
	return;
}

POE::Kernel->run();

sub nickonly {
	my $n = shift;
	$n =~ s/^([^!]+).*/$1/g;
	return $n;
}

sub return_path {
	my $source = nickonly(shift);
	my @targets = @{(shift)};
	return $source if (grep { lc($config->{nick}) eq lc($_) } @targets);
	my @chan_targets = grep { exists($config->{channel}{lc $_}) } @targets;
	return undef unless @chan_targets;
	# Just ignore additional channels, if any
	return $chan_targets[0];
}

sub msg_or_notice($$) {
	my ($target, $msg) = @_;
	my $method = ($target =~ /^#/) ? 'privmsg' : 'notice';
	$irc->yield($method => $target => $msg);
}

sub noisy_check_priv($$$$) {
	my ($rpath, $nick, $priv, $authed) = @_;
	return 0 if (!noisy_command_authed($rpath, $nick, $authed));
	if (!BotDb::has_priv($nick, $priv)) {
		$irc->yield(privmsg => $rpath, "$nick: you are not authorised to perform this action ($priv).");
		return 0;
	}
	return 1;
}
sub noisy_check_antipriv($$$$) {
	my ($rpath, $nick, $priv, $authed) = @_;
	my $account = $authed ? $nick : '!guest';
	if (BotDb::has_priv($account, $priv)) {
		$irc->yield(privmsg => $rpath, "$nick: you are not authorised to perform this action (due to $priv).");
		return 0;
	}
	return 1;
}
sub noisy_command_authed($$$) {
	my ($rpath, $nick, $authed) = @_;
	if (!$authed) {
		$irc->yield(privmsg => $rpath, "$nick: you must be logged in to use this command.");
	}
	return $authed;
}

sub on_irc_public {
	my $nick = nickonly($_[ARG0]);
	return 1 if ($config->{hardcore_ignore} && BotDb::has_priv($nick, 'no_react'));
	return 0 if ($_[ARG2] !~ /^\.([a-z_]+)\s*(.*)$/);
	return BotPlugin::maybe_irc_command($nick, $_[ARG1], lc($1), $2, $_[ARG3]);
}

sub on_irc_msg {
	my $nick = nickonly($_[ARG0]);
	return 1 if ($config->{hardcore_ignore} && BotDb::has_priv($nick, 'no_react'));
	return 0 if ($_[ARG2] !~ /^\.([a-z_]+)\s*(.*)$/);
	return BotPlugin::maybe_irc_command($nick, $_[ARG1], lc($1), $2, $_[ARG3]);
}

sub add_handler($$$) {
	my ($ev, $origin, $code) = @_;
	if ($ev eq "irc_anymsg") {
		&add_handler("irc_msg", $origin, $code);
		&add_handler("irc_public", $origin, $code);
		return;
	}
	if (!exists $handlers{$ev}) {
		$handlers{$ev} = [];
		$kernel->state($ev, sub {
			for (@{$handlers{$ev}}) {
				my $res = $_->{code}(@_);
				last if ($res);
			}
		});
	}
	push @{$handlers{$ev}}, { origin => $origin, code => $code };
}

sub remove_handlers($) {
	my $origin = shift;
	for my $h (keys %handlers) {
		@{$handlers{$h}} = grep { $_->{origin} ne $origin } @{$handlers{$h}};
		$kernel->state($h) if (!@{$handlers{$h}});
	}
}

