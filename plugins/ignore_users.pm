{
	irc_on_public => sub {
		my $nick = BotIrc::nickonly($_[ARG0]);
		return 1 if (BotDb::has_priv($nick, 'no_react'));
	}
};
