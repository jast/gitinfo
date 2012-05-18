use POE;
my %welcomed_users = ();
{
	schemata => {
		0 => [
			"CREATE TABLE welcomed (
				nick TEXT PRIMARY KEY NOT NULL,
				channel TEXT NOT NULL)",
		],
	},
	on_load => sub {
		my $res = $BotDb::db->selectall_arrayref("SELECT nick, channel FROM welcomed", {Slice => {}});
		for (@$res) {
			$welcomed_users{$_->{channel}} //= {};
			$welcomed_users{$_->{channel}}{$_->{nick}} = 1;
		}
	},
	irc_on_public => sub {
		BotIrc::check_ctx() or return 1;
		my $source = BotIrc::ctx_source();
		my $chan = BotIrc::ctx_target('wisdom');
		return 0 if defined $welcomed_users{lc $chan}{lc $source};
		# We'll want to check this first; no need to flag someone if
		# the channel doesn't have a welcome message in the first place
		my $msg;
		return 0 if !defined($msg = $BotIrc::config->{welcome_channels}{lc $chan});

		# No hi first thing? Put them on the naughty list
		goto flag_as_welcomed if $_[ARG2] !~ /^(?:hi|hello|hey)\b/i;
		# arbitrary threshold; prevent responding to an actual question
		goto flag_as_welcomed if length($_[ARG2]) > 15;

		BotIrc::ctx_set_addressee($source);
		BotIrc::send_wisdom($msg);
	    flag_as_welcomed:
		$BotDb::db->do("INSERT INTO welcomed (nick, channel) VALUES(?,?)", {}, lc $source, lc $chan);
		$welcomed_users{lc $chan} //= {};
		$welcomed_users{lc $chan}{lc $source} = 1;
		return 0;
	},
};
