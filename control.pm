package BotCtl;
use common::sense;
use POE;

sub init {
	BotPlugin::add_core_ctl_command('auth', sub {
		my ($client, $data, @args) = @_;
		if (@args != 1) {
			$client->put("error:syntax:This command needs exactly one argument.");
			return 1;
		}
		if (@args == 1 && $args[0] eq $BotIrc::config->{control_pwd}) {
			$client->put("ok");
			$data->{level} = '!control';
		}
		# TODO (perhaps): user auth
	});
}

sub on_connected {
	my $id = $_[HEAP]{client}->ID;
	$_[HEAP]{ctl_sessions}{$id} = {
		client => $_[HEAP]{client},
		level => '!guest',
	};
}

sub on_input {
	my ($heap, $input) = @_[HEAP, ARG0];
	my $client = $heap->{client};
	my $data = client_data($client);

	my ($cmd, @args) = split(/:/, $input);
	for (@args) {
		s/%([0-9a-f]{2})/chr(hex($1))/eig;
	}
	$cmd = lc $cmd;
	if (!BotPlugin::maybe_ctl_command($client, $data, $cmd, @args)) {
		$client->put("error:invalid_command:The given command is not handled by any plugin.");
	}
}

sub send {
	my $client = shift;
	my @args = @_;
	for (@args) { s/%/%25/g; s/:/%3A/g; s/\015/%0D/g; s/\012/%0A/g; }
	$client->put(join(':', @args));
}

sub client_data {
	return $_[HEAP]{ctl_sessions}{shift->ID};
}

sub is_guest { return $_[1]->{level} eq '!guest'; }
sub is_control { return $_[1]->{level} eq '!control'; }

sub get_user {
	my $u = $_[1]->{level};
	return undef if ($u =~ /^!/);
	$u;
}

sub set_level {
	$_[0]->{level} = $_[1];
}

sub require_control {
	return 1 if &is_control;
	$_[0]->put("error:needpriv:Insufficient privileges.");
	return 0;
}

sub require_user {
	return 1 if &is_control || &get_user;
	$_[0]->put("error:needpriv:Insufficient privileges.");
	return 0;
}

1;
