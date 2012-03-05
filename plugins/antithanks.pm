use POE;
{
	irc_on_public => sub {
		BotIrc::check_ctx() or return 1;
		return 0 if (lc(BotIrc::ctx_addressee()) ne lc($BotIrc::irc->nick_name()));
		return 0 if $_[ARG2] !~ /thank/i;

		BotIrc::ctx_set_addressee(BotIrc::ctx_source());
		BotIrc::send_wisdom("you're welcome, but please note that I'm a bot. I'm not programmed to care.");
		return 1;
	},
};
