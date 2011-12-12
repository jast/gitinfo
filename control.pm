package BotCtl;
use common::sense;
use POE;

sub init {}

sub on_connected {
	my $id = $_[HEAP]{client}->ID;
	$_[HEAP]{ctl_sessions}{$id} = {
		client => $_[HEAP]{client},
		level => 'guest',
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

1;
