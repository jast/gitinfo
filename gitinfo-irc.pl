#!/usr/bin/perl
package BotIrc;

use common::sense;
use Carp;
use JSON;
use File::Slurp;
use POE;
use POE::Component::IRC::State;
use POE::Component::IRC::Plugin::AutoJoin;
use POE::Component::IRC::Plugin::Connector;
use POE::Component::IRC::Plugin::NickServID;
use POE::Component::Client::DNS;
use POE::Component::Client::HTTP;
use POE::Component::Server::TCP;
use POE::Filter::Line;
use Socket;
use Socket6;

use lib '.';
use control;
use db;
use http;
use plugin;

our $config;
our $config_file = 'config.json';
	$config_file = $ARGV[0] if (defined($ARGV[0]) && -f $ARGV[0]);
our $kernel;
our %heap;

my %handlers = ();
my %handler_ctx = ();

sub read_config {
	$config = read_file($config_file) or fatal("Config file `$config_file' missing: $!");
	$config = decode_json($config);

	if (ref($config->{channel}) eq '') {
		$config->{channel} = [$config->{channel}];
	}
	my %chans;
	$chans{lc $_} = undef for @{$config->{channel}};
	$config->{channel} = \%chans;
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
	'Password'	=> $config->{server_password},
	'LocalAddr'	=> $config->{local_addr},
	'useipv6'	=> $config->{ipv6},
	'Raw'		=> 1,
);

POE::Component::Client::HTTP->spawn(
	Alias		=> 'http',
	Timeout		=> 30,
	MaxSize		=> 1_000_000,
	FollowRedirects	=> 2,
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
	BotHttp::init();
	$irc->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new(Channels => $config->{channel}));
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
	my $targets = shift;
	my @targets = ();
	if (ref($targets) eq 'ARRAY') {
		@targets = @$targets;
	}

	return $source if (grep { lc($irc->nick_name()) eq lc($_) } @targets);
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

# Convenience methods for handlers {{{

# Called by core stuff that calls handlers; initializes the handler ctx with
# information about which return paths are available in principle. This will
# later be matched against what kinds of return paths a handler requires and
# generate errors if necessary.
sub prepare_ctx_targets($$$$) {
	my ($source, $target, $msg, $authed) = @_;
	my $rpath = return_path($source, $target);
	$rpath = undef if lc($rpath) eq lc($source);
	%handler_ctx = (
		user => $source,
		channel => $rpath,
		line => $msg,
		authed => $authed,
		no_setup => 1,
	);
}

# This is the counterpart to prepare_irc_targets. It's called by handlers to
# perform priv/target checks according to the handler's specs.
# Yay function name overload!
sub check_ctx(%) {
	my %cfg = @_;
	my $authed = $handler_ctx{authed};
	my $source = $handler_ctx{user};
	my $channel = $handler_ctx{channel};
	my $account = $authed ? $source : '!guest';

	if (!%handler_ctx) {
		carp("Trying to use uninitialized handler ctx");
		return 0;
	}

	# First, determine where to send replies to...
	# ... but reuse established values if this isn't the first invocation
	# in the current run of the handler
	my ($noise_prefer_channel, $wisdom_prefer_channel);
	if ($handler_ctx{no_setup}) {
		$noise_prefer_channel = $cfg{noise_public} // $config->{replies_public};
		$wisdom_prefer_channel = $cfg{wisdom_public} // 1;
	} else {
		$noise_prefer_channel = $cfg{noise_public} // ($handler_ctx{noise_target} eq $channel);
		$wisdom_prefer_channel = $cfg{wisdom_public} // ($handler_ctx{wisdom_target} eq $channel);
	}
	if ($noise_prefer_channel && $channel) {
		$handler_ctx{noise_type} = 'privmsg';
		$handler_ctx{noise_target} = $channel;
	} else {
		$handler_ctx{noise_type} = 'notice';
		$handler_ctx{noise_target} = $source;
	}
	if ($wisdom_prefer_channel && $channel) {
		$handler_ctx{wisdom_type} = 'privmsg';
		$handler_ctx{wisdom_target} = $channel;
	} else {
		$handler_ctx{wisdom_type} = 'notice';
		$handler_ctx{wisdom_target} = $source;
	}
	if (exists $cfg{wisdom_addressee}) {
		ctx_set_addressee($cfg{wisdom_addressee});
	} else {
		# We can do this by default without clashing with commands
		# because both only match at the start of the line and a
		# command isn't a valid nickname nor vice versa
		ctx_set_addressee('!auto');
	}
	# Don't auto-redirect by default since it might clash with command
	# syntax
	ctx_auto_redirect($handler_ctx{wisdom_auto_redirect} // 0);
	delete $handler_ctx{no_setup};

	if (($cfg{authed} || defined($cfg{priv})) && !$handler_ctx{authed}) {
		send_noise("You must be logged into NickServ in order to use this command.");
		return 0;
	}
	if (defined $cfg{priv}) {
		$cfg{priv} = [$cfg{priv}] if ref($cfg{priv}) eq '';
		for (@{$cfg{priv}}) {
			if (!BotDb::has_priv($account, $_)) {
				send_noise("You are not authorised to perform this action ($_).");
				return 0;
			}
		}
	}
	if (defined $cfg{antipriv}) {
		$cfg{antipriv} = [$cfg{antipriv}] if ref($cfg{antipriv}) eq '';
		for (@{$cfg{antipriv}}) {
			if (BotDb::has_priv($account, $_)) {
				send_noise("You are not authorised to perform this action (due to $_).");
				return 0;
			}
		}
	}
	return 1;
}

# There are two types of messages sent from handlers: noise and wisdom. Noise
# is stuff like "command successful" or "you lack privileges". Wisdom is stuff
# like "here's the data you requested".

sub send_noise($;$) {
	my $ctx = (ref($_[0]) eq 'HASH') ? shift : \%handler_ctx;
	my $noise = shift;
	if (!%$ctx) {
		carp("A handler tried to send this noise without valid ctx: $noise");
		return;
	}
	if ($ctx->{no_setup}) {
		carp("Handler sending noise without ctx constraints: $noise -> $ctx->{source}");
	}
	# In channels, address user
	$noise = "$ctx->{user}: $noise" if ($ctx->{noise_type} eq 'privmsg');

	$irc->yield($ctx->{noise_type} => $ctx->{noise_target} => $noise);
}

sub send_wisdom($;$) {
	my $ctx = (ref($_[0]) eq 'HASH') ? shift : \%handler_ctx;
	my $wisdom = shift;
	if (!%$ctx) {
		carp("A handler tried to send this wisdom without valid ctx: $wisdom");
		return;
	}
	if ($ctx->{no_setup}) {
		carp("Handler sending wisdom without ctx constraints: $wisdom -> $ctx->{source}");
	}
	my $a = $ctx->{wisdom_addressee};
	my $address = "";
	$address = "$a: " if (defined $a && ctx_target_has_member($ctx, $a));
	$irc->yield($ctx->{wisdom_type} => $ctx->{wisdom_target} => ($address.$wisdom));
}

# Choose who to address in public wisdom. Set to undef to disable or '!auto'
# to enable black magic.
# Note that this is handled during check_ctx, too, and defaults to black magic
# there.
sub ctx_set_addressee($;$) {
	my $ctx = (ref($_[0]) eq 'HASH') ? shift : \%handler_ctx;
	my $a = shift;
	if ($a eq '!auto') {
		$a = undef;
		if ($ctx->{line} && $ctx->{line} =~ /^
				([\w\[\]\{\}\\\|`^{}-]+) # nick (broad match)
				(?:[,:]|\s-+)		 # separator
				\s+/ix) {
			$a = $1;
		}
	}
	$ctx->{wisdom_addressee} = $a;
}

sub ctx_addressee(;$) {
	my $ctx = (ref($_[0]) eq 'HASH') ? shift : \%handler_ctx;
	return $ctx->{"wisdom_addressee"};
}

sub ctx_target($;$) {
	my $ctx = (ref($_[0]) eq 'HASH') ? shift : \%handler_ctx;
	return $ctx->{shift."_target"};
}

sub ctx_source(;$) {
	my $ctx = (ref($_[0]) eq 'HASH') ? shift : \%handler_ctx;
	return $ctx->{user};
}

# This works for wisdom only! Noise should only go to the actual source of a
# message, really.
sub ctx_target_has_member($;$) {
	my $ctx = (ref($_[0]) eq 'HASH') ? shift : \%handler_ctx;
	my $target = $ctx->{wisdom_target};
	return 0 if $target !~ /^#/;
	return $irc->is_channel_member($target, shift);
}

sub ctx_redirect_to_channel($;$$) {
	my $ctx = (ref($_[0]) eq 'HASH') ? shift : \%handler_ctx;
	my ($type, $channel) = @_;
	if (exists($config->{channel}{lc $channel})) {
		$ctx->{"${type}_target"} = $channel;
		$ctx->{"${type}_type"} = 'privmsg';
		return 1;
	}
	return 0;
}

sub ctx_redirect_to_addressee {
	my $ctx = (ref($_[0]) eq 'HASH') ? shift: \%handler_ctx;
	$ctx->{wisdom_target} = $ctx->{wisdom_addressee} // $ctx->{user};
	$ctx->{wisdom_type} = 'notice';
}

# Will redirect wisdom caused by private requests into a channel if the
# request contains "to:#thechannel" and #thechannel is known to us.
sub ctx_auto_redirect(;$) {
	my $ctx = (ref($_[0]) eq 'HASH') ? shift : \%handler_ctx;
	if ($ctx->{line} && !ctx_can_target_channel($ctx) && $ctx->{line} =~ /\bto:(#[\S]+)/) {
		ctx_redirect_to_channel($ctx, 'wisdom', $1);
	}
}

# Was the original message addressed to a known channel?
# This ignores redirections.
sub ctx_can_target_channel(;$) {
	my $ctx = (ref($_[0]) eq 'HASH') ? shift : \%handler_ctx;
	return defined($ctx->{channel});
}

# Get a copy of the current ctx, for use in async scripts
sub ctx_frozen() {
	return {%handler_ctx};
}

# }}}

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
				# Prepare handler ctx
				my ($authed, $msg) = (0, "");
				if ($ev =~ /^irc_(?:msg|public)$/) {
					$authed = $_[ARG3];
					$msg = $_[ARG2];
				}
				prepare_ctx_targets(nickonly($_[ARG0]), $_[ARG1], $msg, $authed);
				my $res = $_->{code}(@_);
				%handler_ctx = ();
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

