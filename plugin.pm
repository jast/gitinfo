package BotPlugin;
use common::sense;

my %plugins = ();
my %control_commands = ();
my %control_states = ();
my %irc_commands = ();

sub init {
	$irc_commands{priv} = sub {
		my ($source, $targets, $args, $auth) = @_;
		BotIrc::check_ctx(priv => 'priv') or return;

		my @args = split(/\s+/, $args, 3);
		if ($args[0] eq 'add') {
			for (split(/\s+/, $args[2])) {
				BotDb::add_priv(lc($args[1]), lc($_));
			}
		} elsif ($args[0] eq 'del') {
			for (split(/\s+/, $args[2])) {
				BotDb::del_priv(lc($args[1]), lc($_));
			}
		} else {
			BotIrc::send_noise("Invalid sub-command.");
			return 1;
		}
		BotIrc::send_noise("Okay.");
		return 1;
	};
	$irc_commands{plugin} = sub {
		my ($source, $targets, $args, $auth) = @_;
		BotIrc::check_ctx(priv => 'plugin') or return;

		my @args = split(/\s+/, $args, 3);
		my $cb = sub { BotIrc::send_noise(shift) };
		if ($args[0] eq 'load') {
			load($args[1], $cb, $cb);
		} elsif ($args[0] eq 'unload') {
			unload($args[1], $cb, $cb);
		} elsif ($args[0] eq 'reload') {
			unload($args[1], $cb, $cb);
			load($args[1], $cb, $cb);
		} else {
			BotIrc::send_noise("Invalid sub-command.");
			return 1;
		}
	};
	$irc_commands{rehash} = sub {
		my ($source, $targets, $args, $auth) = @_;
		BotIrc::check_ctx(priv => 'rehash') or return;

		# TODO: apply changes live as possible
		# $old_config = $BotIrc::config;
		BotIrc::read_config();
		BotIrc::send_noise("Okay.");
	};
	$irc_commands{user} = sub {
		my ($source, $targets, $args, $auth) = @_;
		BotIrc::check_ctx(priv => 'user') or return;

		my @args = split(/\s+/, $args);
		if (@args != 2) {
			BotIrc::send_noise("Wrong number of args.");
			return 1;
		}
		if ($args[0] eq 'add') {
			BotDb::add_user(lc($args[1]));
		} elsif ($args[0] eq 'del') {
			BotDb::del_user(lc($args[1]));
		} else {
			BotIrc::send_noise("Invalid sub-command.");
			return 1;
		}
		BotIrc::send_noise("Okay.");
		return 1;
	};
}

sub load($;$$) {
	my $name = shift;
	my $error = shift // \&BotIrc::error;
	my $info = shift // \&BotIrc::info;
	my $p;
	if ($name eq 'core') {
		$error->("Can't load plugin 'core': reserved name");
		return undef;
	}
	if (exists $plugins{$name}) {
		$error->("Plugin '$name' already loaded.");
		return $plugins{$name};
	}
	unless ($p = do "plugins/$name.pm") {
		$error->("Couldn't parse plugin '$name': $@") if $@;
		$error->("Couldn't read plugin '$name': $!") if $!;
		return undef;
	}

	my @dbinfo = $BotDb::db->selectrow_array("SELECT * FROM plugins WHERE name=?", {}, $name);
	if (!@dbinfo) {
		$info->("Installing plugin '$name' during first load...");
		$BotDb::db->do("INSERT INTO plugins VALUES(?, 0)", {}, $name);
		$p->{on_install}($error, $info) if exists $p->{on_install};
	}
	if (exists $p->{dependencies}) {
		for ($p->{dependencies}) {
			next if (exists $plugins{$_});
			$info->("Loading dependency '$_'...");
			if (!&load($_)) {
				$error->("Aborting load of '$name' due to the above error in dependency '$_'");
				return undef;
			}
		}
	}
	if (exists $p->{schemata}) {
		BotDb::update_schema($name, $p->{schemata}, $error, $info) or return undef;
	}

	_import_excl_handlers($p, $name, 'control_commands', \%control_commands, $error) or return 0;
	_import_excl_handlers($p, $name, 'control_states', \%control_states, $error) or return 0;
	_import_excl_handlers($p, $name, 'irc_commands', \%irc_commands, $error) or return 0;

	for (keys %$p) {
		next if !/^irc_on_(.+)$/;
		BotIrc::add_handler("irc_$1", $name, $p->{$_});
	}
	$p->{on_load}($error, $info) if exists $p->{on_load};
	$plugins{$name} = $p;
	$info->("Plugin '$name' loaded.");
	return $p;
}

sub unload($) {
	my $name = shift;
	my $error = shift // \&BotInfo::error;
	my $info = shift // \&BotInfo::info;
	return if !exists $plugins{$name};
	$plugins{$name}{before_unload}($error, $info) if exists $plugins{$name}{before_unload};
	_unimport_excl_handlers($name, 'control_commands', \%control_commands);
	_unimport_excl_handlers($name, 'control_states', \%control_states);
	_unimport_excl_handlers($name, 'irc_commands', \%irc_commands);
	BotIrc::remove_handlers($name);
	delete $plugins{$name};
	$info->("Plugin '$name' unloaded.");
}

# Interface used by other parts of the core ############################## {{{

sub maybe_irc_command($$$$$) {
	my ($source, $targets, $cmd, $args, $auth) = @_;
	return 0 if (!exists $irc_commands{$cmd});
	$irc_commands{$cmd}($source, $targets, $args, $auth);
	return 1;
}

sub maybe_ctl_command($$$$) {
	my ($client, $data, $cmd, @args) = @_;
	return 0 if (!exists $control_commands{$cmd});
	$control_commands{$cmd}($client, $data, @args);
	return 1;
}

sub add_core_ctl_command($$) {
	my ($cmd, $code) = @_;
	$control_commands{$cmd} = $code;
}

# }}}

# Internal helpers ####################################################### {{{

sub _import_excl_handlers($$$$) {
	my ($p, $name, $type, $target, $error) = @_;
	$error //= \&BotIrc::error;
	my $eh = $p->{$type};
	my @eh = grep { exists $target->{$_} } keys(%$eh);
	if (@eh) {
		$error->("While loading plugin $name: plugin tried to redefine the following $type: ".join(', ', @eh));
		return 0;
	}
	for (keys %$eh) { $target->{$_} = $eh->{$_}}
	return 1;
}

sub _unimport_excl_handlers($$) {
	my ($name, $type, $target) = @_;
	my $p = $plugins{$name};
	my $eh = $p->{$type};
	for (keys %$eh) { delete $target->{$_}; }
}

# }}}

1;
