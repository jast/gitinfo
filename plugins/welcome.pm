use POE;
my %joined_users = ();
{
	irc_on_join => sub {
		$joined_users{BotIrc::nickonly(lc $_[ARG0])} = 1;
	},
	irc_on_public => sub {
		BotIrc::check_ctx() or return 1;
		my $source = BotIrc::ctx_source();
		my $chan = BotIrc::ctx_target('wisdom');
		return 0 if !exists $joined_users{lc $source};
		delete $joined_users{lc $source};
		return 0 if $_[ARG2] !~ /^(?:hi|hello)\b/i;
		# arbitrary threshold; prevent responding to an actual question
		return 0 if length($_[ARG2]) > 15;
		my $msg;
		return 0 if !defined($msg = $BotIrc::config->{welcome_channels}{lc $chan});

		BotIrc::ctx_set_addressee($source);
		BotIrc::send_wisdom($msg);
		return 1;
	},
};
